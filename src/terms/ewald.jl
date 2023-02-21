import SpecialFunctions: erfc

"""
Ewald term: electrostatic energy per unit cell of the array of point
charges defined by `model.atoms` in a uniform background of
compensating charge yielding net neutrality.
"""
struct Ewald end
(::Ewald)(basis) = TermEwald(basis)

struct TermEwald{T} <: Term
    energy::T  # precomputed energy
end
function TermEwald(basis::PlaneWaveBasis{T}) where {T}
    TermEwald(T(energy_ewald(basis.model)))
end

function ene_ops(term::TermEwald, basis::PlaneWaveBasis, ψ, occupation; kwargs...)
    (; E=term.energy, ops=[NoopOperator(basis, kpt) for kpt in basis.kpoints])
end

@timing "forces: Ewald" function compute_forces(term::TermEwald, basis::PlaneWaveBasis{T},
                                                ψ, occupation; kwargs...) where {T}
    # TODO this could be precomputed
    forces = zero(basis.model.positions)
    energy_ewald(basis.model; forces)
    forces
end

function energy_ewald(model::Model{T}; kwargs...) where {T}
    isempty(model.atoms) && return zero(T)
    charges = T.(charge_ionic.(model.atoms))
    energy_ewald(model.lattice, charges, model.positions; kwargs...)
end

# To compute the electrostatics of the system, we use the Ewald splitting method due to the
# slow convergence of the energy in ``1/r``.
# It uses the the identity ``1/r ≡ erf(η·r)/r + erfc(η·r)/r``, where the first (smooth) part
# of the energy term is computed in the reciprocal space and the second (singular) one in
# the real-space.
# `η` is an arbitrary parameter that enables to balance the computation of those to parts.
# By default, we choose it to have a slight bias towards the reciprocal summation.
function default_η(lattice::AbstractArray{T}) where {T}
    any(iszero.(eachcol(lattice))) && return  # We won't compute anything
    recip_lattice = compute_recip_lattice(lattice)
    sqrt(sqrt(T(1.69) * norm(recip_lattice ./ 2T(π)) / norm(lattice))) / 2
end

# This could be merged with Pairwise, but its use of `atom_types` would slow down this
# computationally intensive Ewald sums. So we leave it as it for now.
"""
Computes the local energy and forces on the atoms of the reference unit cell 0, for an
infinite array of atoms at positions r_{iR} = positions[i] + R + ph_disp[i]*e^{iq·R} in
a uniform background of compensating charge to yield net neutrality.
`lattice` should contain the lattice vectors as columns. `charges` and `positions` are the
point charges and their positions (as an array of arrays) in fractional coordinates. If
`forces` is not nothing, minus the derivatives of the energy with respect to `positions` is
computed.

`q` is the phonon `q`-point (`Vec3`), and `ph_disp` a list of `Vec3` displacements to
compute the Fourier transform of the force constant matrix.

For now this function returns zero energy and force on non-3D systems. Use a pairwise
potential term if you want to customise this treatment.
"""
function energy_ewald(lattice::AbstractArray{T}, charges, positions; η=default_η(lattice),
                      forces=nothing, q=nothing, ph_disp=nothing) where {T}
    # TODO should something more clever be done here? For now
    # we assume that we are not interested in the Ewald
    # energy of non-3D systems
    any(iszero.(eachcol(lattice))) && return zero(T)

    recip_lattice = compute_recip_lattice(lattice)
    @assert length(charges) == length(positions)
    if !isnothing(ph_disp)
        @assert !isnothing(q) && !isnothing(forces)
        @assert size(ph_disp) == size(positions)
    end
    if !isnothing(forces)
        @assert size(forces) == size(positions)
        forces_real = copy(forces)
        forces_recip = copy(forces)
    end

    # Numerical cutoffs to obtain meaningful contributions. These are very conservative.
    # The largest argument to the exp(-x) function
    max_exp_arg = -log(eps(T)) + 5  # add some wiggle room
    max_erfc_arg = sqrt(max_exp_arg)  # erfc(x) ~= exp(-x^2)/(sqrt(π)x) for large x

    # Precomputing summation bounds from cutoffs.
    # In the reciprocal-space term we have exp(-||B G||^2 / 4η^2),
    # where B is the reciprocal-space lattice, and
    # thus use the bound  ||B G|| / 2η ≤ sqrt(max_exp_arg)
    Glims = estimate_integer_lattice_bounds(recip_lattice, sqrt(max_exp_arg) * 2η)

    # In the real-space term we have erfc(η ||A(rj - rk - R)||),
    # where A is the real-space lattice, rj and rk are atomic positions and
    # thus use the bound  ||A(rj - rk - R)|| * η ≤ max_erfc_arg
    poslims = [maximum(rj[i] - rk[i] for rj in positions for rk in positions) for i in 1:3]
    Rlims = estimate_integer_lattice_bounds(lattice, max_erfc_arg / η, poslims)

    #
    # Reciprocal space sum
    #
    # Initialize reciprocal sum with correction term for charge neutrality
    sum_recip::T = - (sum(charges)^2 / 4η^2)

    for G1 in -Glims[1]:Glims[1], G2 in -Glims[2]:Glims[2], G3 in -Glims[3]:Glims[3]
        G = Vec3(G1, G2, G3)
        iszero(G) && continue
        Gsq = norm2(recip_lattice * G)
        cos_strucfac = sum(Z * cos2pi(dot(r, G)) for (r, Z) in zip(positions, charges))
        sin_strucfac = sum(Z * sin2pi(dot(r, G)) for (r, Z) in zip(positions, charges))
        sum_strucfac = cos_strucfac^2 + sin_strucfac^2
        sum_recip += sum_strucfac * exp(-Gsq / 4η^2) / Gsq
        if !isnothing(forces)
            for (ir, r) in enumerate(positions)
                Z = charges[ir]
                dc = -Z*2T(π)*G*sin2pi(dot(r, G))
                ds = +Z*2T(π)*G*cos2pi(dot(r, G))
                dsum = 2cos_strucfac*dc + 2sin_strucfac*ds
                forces_recip[ir] -= dsum * exp(-Gsq / 4η^2)/Gsq
            end
        end
    end

    # Amend sum_recip by proper scaling factors:
    sum_recip *= 4T(π) / compute_unit_cell_volume(lattice)
    if !isnothing(forces)
        forces_recip .*= 4T(π) / compute_unit_cell_volume(lattice)
    end

    #
    # Real-space sum
    #
    S = isnothing(ph_disp) ? T : promote_type(complex(T), eltype(ph_disp[1]))
    # Initialize real-space sum with correction term for uniform background
    sum_real::S = -2η / sqrt(S(π)) * sum(Z -> Z^2, charges)

    for R1 in -Rlims[1]:Rlims[1], R2 in -Rlims[2]:Rlims[2], R3 in -Rlims[3]:Rlims[3]
        R = Vec3(R1, R2, R3)
        for i = 1:length(positions), j = 1:length(positions)
            # Avoid self-interaction
            iszero(R) && i == j && continue
            Zi = charges[i]
            Zj = charges[j]
            ti = positions[i]
            tj = positions[j] + R
            if !isnothing(ph_disp)
                ti += ph_disp[i]  # * cis2pi(dot(q, zeros(3))) === 1
                                  #  as we use the forces at the nuclei in the unit cell
                tj += ph_disp[j] * cis2pi(dot(q, R))
            end
            Δr = lattice * (ti .- tj)
            dist = norm_cplx(Δr)
            energy_contribution = Zi * Zj * erfc(η * dist) / dist
            sum_real += energy_contribution
            if !isnothing(forces)
                # `dE_ddist` is the derivative of `energy_contribution` w.r.t. `dist`
                # dE_ddist = Zi * Zj * η * (-2exp(-(η * dist)^2) / sqrt(T(π)))
                dE_ddist = ForwardDiff.derivative(zero(T)) do ε
                    Zi * Zj * erfc(η * (dist + ε))
                end
                dE_ddist -= energy_contribution
                dE_ddist /= dist
                dE_dti = lattice' * ((dE_ddist / dist) * Δr)
                forces_real[i] -= dE_dti
            end
        end
    end
    energy = (sum_recip + sum_real) / 2  # Divide by 2 (because of double counting)
    if !isnothing(forces)
        forces .= forces_real
        if isnothing(ph_disp)
            forces .+= forces_recip ./ 2
        end
    end
    energy
end

# TODO: See if there is a way to express this with AD.
function dynmat_ewald_recip(model::Model{T}, τ, σ; η=default_η(lattice),
                            q=zero(Vec3{T})) where {T}
    # Numerical cutoffs to obtain meaningful contributions. These are very conservative.
    # The largest argument to the exp(-x) function
    max_exp_arg = -log(eps(T)) + 5  # add some wiggle room

    lattice       = model.lattice
    recip_lattice = model.recip_lattice
    # Precomputing summation bounds from cutoffs.
    # In the reciprocal-space term we have exp(-||B G||^2 / 4η^2),
    # where B is the reciprocal-space lattice, and
    # thus use the bound  ||B G|| / 2η ≤ sqrt(max_exp_arg)
    Glims = estimate_integer_lattice_bounds(recip_lattice, sqrt(max_exp_arg) * 2η)

    charges   = T.(charge_ionic.(model.atoms))
    positions = model.positions
    @assert length(charges) == length(positions)
    pτ = positions[τ]
    pσ = positions[σ]

    dynmat_recip = zeros(T, (length(q), length(q)))
    for G1 in -Glims[1]:Glims[1], G2 in -Glims[2]:Glims[2], G3 in -Glims[3]:Glims[3]
        G = Vec3(G1, G2, G3)
        if !iszero(G + q)
            Gsqq = sum(abs2, recip_lattice * (G + q))
            term = exp(-Gsqq / 4η^2) / Gsqq * charges[σ] * charges[τ]
            term *= cis2pi(dot(G + q, pσ - pτ))
            term *= (2T(π) * im * (G + q)) * (2T(π) * im * (G + q))'
            dynmat_recip += term
        end

        (iszero(G) || σ ≢ τ) && continue
        Gsq = sum(abs2, recip_lattice * G)

        strucfac = sum(Z * cis2pi(dot(r, G)) for (r, Z) in zip(positions, charges))
        dsum = charges[σ] * conj(strucfac) * cis2pi(dot(G, pσ))
        dsum *= (2T(π) * im * G) * (2T(π) * im * G)'
        dsum += conj(dsum)
        dynmat_recip -= 0.5 * exp(-Gsq / 4η^2) / Gsq * dsum
    end

    # Amend `dynmat_recip` by proper scaling factors:
    dynmat_recip *= 4T(π) / compute_unit_cell_volume(lattice)
end

# Computes the Fourier transform of the force constant matrix of the Ewald term.
function dynmat_ewald(model::Model{T}; η=default_η(model.lattice), q=zero(Vec3{T})) where {T}
    n_atoms = length(model.positions)
    n_dim = model.n_dim

    dynmat = zeros(complex(T), (n_dim, n_atoms, n_dim, n_atoms))
    # Real part
    for τ in 1:n_atoms
        for γ in 1:n_dim
            displacement = zero.(model.positions)
            displacement[τ] = setindex(displacement[τ], one(T), γ)
            dynmat_real_τγ = -ForwardDiff.derivative(zero(T)) do ε
                forces = zeros(Vec3{complex(eltype(ε))}, n_atoms)
                energy_ewald(model; η, forces, ph_disp=ε .* displacement, q)
                hcat(Array.(forces)...)
            end
            dynmat[:, :, γ, τ] = dynmat_real_τγ[1:n_dim, :]
        end
    end
    # Reciprocal part
    for τ in 1:n_atoms
        for σ in 1:n_atoms
            dynmat[:, σ, :, τ] += dynmat_ewald_recip(model, σ, τ; η, q)
        end
    end
    reshape(dynmat, n_dim*n_atoms, n_dim*n_atoms)
end

function compute_dynmat(::TermEwald, scfres::NamedTuple;
                        η=default_η(scfres.basis.model.lattice),
                        q=zero(Vec3{eltype(scfres.basis)}), kwargs...)
    dynmat_ewald(scfres.basis.model; η, q)
end
