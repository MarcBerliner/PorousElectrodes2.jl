function build_auxiliary_states!(states, p::AbstractParam)
    """
    Calculates necessary auxiliary states and adds them to the `state` dict
    """
    
    # create a state j_aging which is a combination of j and j_s
    build_j_aging!(states, p)

    # The final value of the x vector can either be I or P,
    # so this function specifically designates the I and P states
    build_I_V_P!(states, p)

    # Temperature, T
    build_T!(states, p)

    # Surface average concentration, c_s_star
    build_c_s_star!(states, p)

    # Open circuit voltages, U
    build_OCV!(states, p)

    # Overpotentials, η
    build_η!(states, p)

    # Electrolyte conductivity, K_eff
    build_K_eff!(states, p)
    
    return nothing
end

function build_I_V_P!(states, p::AbstractParam)
    """
    Define the current, voltage, and power.
    """

    Φ_s = states[:Φ_s]

    I1C = calc_I1C(p)
    
    I = states[:I][1]*I1C
    V = Φ_s[1] - Φ_s[end]
    P = I*V
    
    states[:I] = state_new([I], (), p)
    states[:V] = state_new([V], (), p)
    states[:P] = state_new([P], (), p)

    return nothing
end

function build_j_aging!(states, p::AbstractParam)
    """
    Append `j` with possible additions from `j_s`
    """
    j = states[:j]
    states[:j] = states[:j_orig] = states[:j_aging] = state_new(j, (:p, :n), p)
    
    if !(p.numerics.aging ∈ (:SEI, :R_aging))
        return nothing
    end
    
    j_s = states[:j_s]

    j_aging = copy(j)
    j_aging[p.N.p+1:end] .+= j_s

    states[:j_aging] = state_new(j_aging, (:p, :n), p)
    # redefine the ionic flux
    states[:j] = state_new(j_aging, (:p, :n), p)

    return nothing
end

function build_T!(states, p::AbstractParam)
    """
    If temperature is not enabled, include a vector of temperatures using the specified initial temperature.
    """
    if isempty(states[:T])
        T = repeat([p.θ[:T₀]], (p.N.p+p.N.s+p.N.n+p.N.a+p.N.z))
        
        states[:T] = state_new(T, (:a, :p, :s, :n, :z), p)
    elseif length(states[:T]) === 1
        T = repeat([states[:T]], (p.N.p+p.N.s+p.N.n+p.N.a+p.N.z))
        
        states[:T] = state_new(T, (:a, :p, :s, :n, :z), p)
    end
    
    return nothing
end

function build_c_s_star!(states, p::AbstractParam)
    """
    Evaluates the concentration of Li-ions at the electrode surfaces.
    """
    c_s_avg = states[:c_s_avg]
    j = states[:j]
    Q = states[:Q]
    T = states[:T]
    
    # Check what kind of solid diffusion model has been chosen.
    if p.numerics.solid_diffusion ∈ (:quadratic, :polynomial)

        # Diffusion coefficients for the solid phase
        D_sp_eff, D_sn_eff = p.numerics.D_s_eff(c_s_avg.p, c_s_avg.n, T.p, T.n, p)
        if p.numerics.solid_diffusion === :quadratic # Two peters model
            # Evaluates the average surface concentration in both the electrodes.
            # Cathode
            c_s_star_p = c_s_avg.p-(p.θ[:Rp_p]./(D_sp_eff.*5)).*j.p
            # Anode
            c_s_star_n = c_s_avg.n-(p.θ[:Rp_n]./(D_sn_eff.*5)).*j.n
        elseif p.numerics.solid_diffusion === :polynomial # Three peters model
            
            # Cathode
            c_s_star_p = c_s_avg.p+(p.θ[:Rp_p]./(D_sp_eff.*35)).*(-j.p+8*D_sp_eff.*Q.p)
            # Anode
            c_s_star_n = c_s_avg.n+(p.θ[:Rp_n]./(D_sn_eff.*35)).*(-j.n+8*D_sn_eff.*Q.n)
        end

    # Fickian diffusion
    elseif p.numerics.solid_diffusion === :Fickian
        p_indices = p.N.r_p:p.N.r_p:p.N.r_p*p.N.p
        n_indices = p.N.r_n:p.N.r_n:p.N.r_n*p.N.n
        
        c_s_star_p = c_s_avg.p[p_indices]
        c_s_star_n = c_s_avg.n[n_indices]
    end
    # Return the residuals
    c_s_star = [c_s_star_p; c_s_star_n]

    states[:c_s_star] = state_new(c_s_star, (:p, :n), p)

    return nothing
end

function build_OCV!(states, p::AbstractParam)
    """
    Calculate the open circuit voltages for the positive & negative electrodes
    """
    c_s_star = states[:c_s_star]
    T = states[:T]
    
    # Put the surface concentration into a fraction
    θ_p = c_s_star.p./p.θ[:c_max_p]
    θ_n = c_s_star.n./p.θ[:c_max_n]
    
    # Compute the OCV for the positive & negative electrodes.
    U_p, ∂U∂T_p = p.numerics.OCV_p(θ_p, T.p, p)
    U_n, ∂U∂T_n = p.numerics.OCV_n(θ_n, T.n, p)

    states[:U] = state_new([U_p; U_n], (:p, :n), p)
    states[:∂U∂T] = state_new([∂U∂T_p; ∂U∂T_n], (:p, :n), p)

    return nothing
end

function build_η!(states, p::AbstractParam)
    """
    Calculate the overpotentials for the positive & negative electrodes
    """

    Φ_s = states[:Φ_s]
    Φ_e = states[:Φ_e]
    U = states[:U]
    j = states[:j_aging]
    # j_aging = states[:j_aging]
    film = states[:film]

    F = const_Faradays
    R = const_Ideal_Gas

    η_p = @. Φ_s.p - Φ_e.p - U.p
    η_n = @. Φ_s.n - Φ_e.n - U.n

    if haskey(p.θ, :R_film_n)
        η_n .+= -j.n.*p.θ[:R_film_n]
    end
    
    if     p.numerics.aging === :SEI
        η_n .+= @. - F*j.n*(p.θ[:R_SEI] + film/p.θ[:k_n_aging])
    elseif p.numerics.aging === :R_aging
        η_n .+= @. - F*j.n*p.θ[:R_aging]
    end

    states[:η] = state_new([η_p; η_n], (:p, :n), p)

    return nothing
end

function build_K_eff!(states, p::AbstractParam)
    c_e = states[:c_e]
    T = states[:T]

    K_eff_p, K_eff_s, K_eff_n = p.numerics.K_eff(c_e.p, c_e.s, c_e.n, T.p, T.s, T.n, p)

    states[:K_eff] = state_new([K_eff_p; K_eff_s; K_eff_n], (:p, :s, :n), p)
    
    return nothing
end

function build_heat_generation_rates!(states, p::AbstractParam)
    """
    Evaluates the heat source terms used in the thermal model per section
    """

    Φ_s = states[:Φ_s]
    Φ_e = states[:Φ_e]
    j = states[:j_aging]
    T = states[:T]
    c_e = states[:c_e]
    ∂U∂T = states[:∂U∂T]
    η = states[:η]
    K_eff = states[:K_eff]

    F = const_Faradays
    R = const_Ideal_Gas

    a_p, a_n = surface_area_to_volume_ratio(p)
    σ_eff_p, σ_eff_n = conductivity_effective(p)

    function thermal_derivatives(Φ_s, Φ_e, c_e, p)

        # For each of the numerical derivatives computed below; the first & last control volumes are evaluated with first
        # order accuracy [forward & backward difference schemes respectively]
        # while the middle control volume approximations use a second order accuracy [central difference scheme].
    
        Δx = Δx_values(p.N)
    
        ## Solid potential derivatives
    
        # Positive Electrode
        dΦ_sp = [(-3*Φ_s[1]+4*Φ_s[2]-Φ_s[3])/(2*Δx.p*p.θ[:l_p]);           					# Forward differentiation scheme
            (Φ_s[3:p.N.p]-Φ_s[1:p.N.p-2]) / (2*Δx.p*p.θ[:l_p]);						# Central differentiation scheme
            (3*Φ_s[p.N.p]-4*Φ_s[p.N.p-1]+Φ_s[p.N.p-2]) / (2*Δx.p*p.θ[:l_p])		# Backward differentiation scheme
            ]
    
        # Negative Electrode
        dΦ_sn = [(-3*Φ_s[p.N.p+1]+4*Φ_s[p.N.p+2]-Φ_s[p.N.p+3])/(2*Δx.n*p.θ[:l_n]); 	# Forward differentiation scheme
            (Φ_s[p.N.p+3:end]-Φ_s[p.N.p+1:end-2]) / (2*Δx.n*p.θ[:l_n]); 					# Central differentiation scheme
            (3*Φ_s[end]-4*Φ_s[end-1]+Φ_s[end-2]) / (2*Δx.n*p.θ[:l_n]) 						# Backward differentiation scheme
            ]
    
        dΦ_s = (
            p = dΦ_sp,
            n = dΦ_sn,
            )
    
        ## Electrolyte potential derivatives
    
        # Positive Electrode
    
        dΦ_ep = [ (-3*Φ_e[1]+4*Φ_e[2]-Φ_e[3])/(2*Δx.p*p.θ[:l_p]);		# Forward differentiation scheme
            (Φ_e[3:p.N.p]-Φ_e[1:p.N.p-2])/(2*Δx.p*p.θ[:l_p])	  	# Central differentiation scheme
            ]
    
        # Attention! The last volume of the positive electrode will involve one volume of the
        # separator for the calculation of the derivative. Therefore suitable
        # considerations must be done with respect to the deltax quantities.
    
        # Last CV in the positive electrode: derivative approximation with a central scheme
        dΦ_e_last_p = 2*(Φ_e[p.N.p+1]-Φ_e[p.N.p-1])/(3 * Δx.p*p.θ[:l_p] + Δx.s*p.θ[:l_s])
    
        # Separator
    
        # Attention! The first volume of the separator will involve one volume of the
        # positive section for the calculation of the derivative. Therefore suitable
        # considerations must be done with respect to the deltax quantities.
    
        # First CV in the separator: derivative approximation with a central difference scheme
        dΦ_e_first_s = 2*(Φ_e[p.N.p+2]-Φ_e[p.N.p])/(Δx.p*p.θ[:l_p] + 3* Δx.s*p.θ[:l_s])
    
        # Central difference scheme
        dΦ_es =  (Φ_e[p.N.p+3:p.N.p+p.N.s]-Φ_e[p.N.p+1:p.N.p+p.N.s-2])/(2*Δx.s*p.θ[:l_s])
    
        # Attention! The last volume of the separator will involve one volume of the
        # negative section for the calculation of the derivative. Therefore suitable
        # considerations must be done with respect to the deltax quantities.
    
        # Last CV in the separator: derivative approximation with a central scheme
        dΦ_e_last_s = 2*(Φ_e[p.N.p+p.N.s+1]-Φ_e[p.N.p+p.N.s-1])/( Δx.n*p.θ[:l_n] + 3*Δx.s*p.θ[:l_s])
    
        # Negative electrode
    
        # Attention! The first volume of the negative electrode will involve one volume of the
        # separator section for the calculation of the derivative. Therefore suitable
        # considerations must be done with respect to the deltax quantities.
    
        # First CV in the negative electrode: derivative approximation with a central scheme
        dΦ_e_first_n = 2*(Φ_e[p.N.p+p.N.s+2]-Φ_e[p.N.p+p.N.s])/(3 * Δx.n*p.θ[:l_n] + Δx.s*p.θ[:l_s])
    
        # Central difference scheme
        dΦ_en = [(Φ_e[p.N.p+p.N.s+3:end]-Φ_e[p.N.p+p.N.s+1:end-2])/(2*Δx.n*p.θ[:l_n]);
            (3*Φ_e[end]-4*Φ_e[end-1]+Φ_e[end-2])/(2*Δx.n*p.θ[:l_n])
            ]
        dΦ_e = (
            p = [dΦ_ep;dΦ_e_last_p],
            s = [dΦ_e_first_s;dΦ_es;dΦ_e_last_s],
            n = [dΦ_e_first_n;dΦ_en],
        )
    
        ## Electrolyte concentration derivatives
    
        # Positive Electrode
    
        dc_ep = [ (-3*c_e[1]+4*c_e[2]-c_e[3])/(2*Δx.p*p.θ[:l_p]); 		# Forward differentiation scheme
            (c_e[3:p.N.p]-c_e[1:p.N.p-2])/(2*Δx.p*p.θ[:l_p]) 	# Central differentiation scheme
            ]
    
        # Attention! The last volume of the positive electrode will involve one volume of the
        # separator for the calculation of the derivative. Therefore suitable
        # considerations must be done with respect to the deltax quantities.
    
        # Last CV in the positive electrode: derivative approximation with a central scheme
        dc_e_last_p = 2*(c_e[p.N.p+1]-c_e[p.N.p-1])/(3 * Δx.p*p.θ[:l_p] + Δx.s*p.θ[:l_s])
    
        # Separator
    
        # Attention! The first volume of the separator will involve one volume of the
        # positive section for the calculation of the derivative. Therefore suitable
        # considerations must be done with respect to the deltax quantities.
    
        # First CV in the separator: derivative approximation with a central scheme
        dc_e_first_s = 2*(c_e[p.N.p+2]-c_e[p.N.p])/( Δx.p*p.θ[:l_p] + 3* Δx.s*p.θ[:l_s])
    
        # Central differentiation scheme
        dc_es = (c_e[p.N.p+3:p.N.p+p.N.s]-c_e[p.N.p+1:p.N.p+p.N.s-2])/(2*Δx.s*p.θ[:l_s])
    
        # Attention! The last volume of the separator will involve one volume of the
        # negative section for the calculation of the derivative. Therefore suitable
        # considerations must be done with respect to the deltax quantities.
    
        # Last CV in the separator: derivative approximation with a central scheme
        dc_e_last_s = 2*(c_e[p.N.p+p.N.s+1]-c_e[p.N.p+p.N.s-1])/( Δx.n*p.θ[:l_n] + 3*Δx.s*p.θ[:l_s])
    
        # Negative electrode
    
        # Attention! The first volume of the negative electrode will involve one volume of the
        # separator section for the calculation of the derivative. Therefore suitable
        # considerations must be done with respect to the deltax quantities.
    
        # First CV in the negative electrode: derivative approximation with a central scheme
        dc_e_first_n = 2*(c_e[p.N.p+p.N.s+2]-c_e[p.N.p+p.N.s])/(3 * Δx.n*p.θ[:l_n] + Δx.s*p.θ[:l_s])
    
        dc_en = [(c_e[p.N.p+p.N.s+3:end]-c_e[p.N.p+p.N.s+1:end-2])/(2*Δx.p*p.θ[:l_p]); 	# Central differentiation scheme
            (3*c_e[end]-4*c_e[end-1]+c_e[end-2])/(2*Δx.n*p.θ[:l_n]) 						# Backward differentiation scheme
            ]
    
        dc_e = (
            p = [dc_ep;dc_e_last_p],
            s = [dc_e_first_s;dc_es;dc_e_last_s],
            n = [dc_e_first_n;dc_en],
        )
    
        return dΦ_s, dΦ_e, dc_e
    end

    # Evaluate the derivatives used in Q_ohm calculations
    dΦ_s, dΦ_e, dc_e = thermal_derivatives(Φ_s, Φ_e, c_e, p)

    ## Reversible heat generation rate

    # Positive electrode
    @views @inbounds Q_rev_p = F*a_p*j.p.*T.p.*∂U∂T.p

    # Negative Electrode
    @views @inbounds Q_rev_n = F*a_n*j.n.*T.n.*∂U∂T.n

    ## Reaction heat generation rate
    # Positive reaction heat generation rate
    @views @inbounds Q_rxn_p = F*a_p*j.p.*η.p

    # Negative reaction heat generation rate
    @views @inbounds Q_rxn_n = F*a_n*j.n.*η.n

    ## Ohmic heat generation rate
    ν_p, ν_s, ν_n = p.numerics.thermodynamic_factor(c_e.p, c_e.s, c_e.n, T.p, T.s, T.n, p)

    # Positive electrode ohmic generation rate
    Q_ohm_p = σ_eff_p * dΦ_s.p.^2 + K_eff.p.*dΦ_e.p.^2 + 2*R*K_eff.p.*T.p*(1-p.θ[:t₊]).*ν_p/F.*(dc_e.p./c_e.p).*dΦ_e.p
    # Separator ohmic generation rate
    Q_ohm_s = K_eff.s.*dΦ_e.s.^2 + 2*R*K_eff.s.*T.s*(1-p.θ[:t₊]).*ν_s/F.*dc_e.s.*1.0./c_e.s.*dΦ_e.s
    # Negative electrode ohmic generation rate
    Q_ohm_n = σ_eff_n * dΦ_s.n.^2 + K_eff.n.*dΦ_e.n.^2 + 2*R*K_eff.n.*T.n*(1-p.θ[:t₊]).*ν_n/F.*(dc_e.n./c_e.n).*dΦ_e.n
    
    Q_rev = [Q_rev_p; Q_rev_n]
    Q_rxn = [Q_rxn_p; Q_rxn_n]
    Q_ohm = [Q_ohm_p; Q_ohm_s; Q_ohm_n]

    states[:Q_rev] = state_new(Q_rev, (:p, :n), p)
    states[:Q_rxn] = state_new(Q_rxn, (:p, :n), p)
    states[:Q_ohm] = state_new(Q_ohm, (:p, :s, :n), p)

    return nothing
end

function build_residuals!(res_tot::AbstractVector, res::Dict, p::AbstractParam)
    """
    Create the residuals vector using all the variables which are needed in the simulation.
    `p.cache.vars` contains the list of variables, and `getproperty(p.ind, var)` will
    retrieve the appropriate indices for all the variables
    """
    @inbounds for var in p.cache.vars
        ind_var = getproperty(p.ind, var)
        res_tot[ind_var] .= res[var]
    end
    return nothing
end


"""
Constants and coefficients
"""
function active_material(p::AbstractParam)
    """
    Electrode active material fraction [-]
    """
    ϵ_sp = 1.0 - (p.θ[:ϵ_fp] + p.θ[:ϵ_p])
    ϵ_sn = 1.0 - (p.θ[:ϵ_fn] + p.θ[:ϵ_n])

    return ϵ_sp, ϵ_sn
end

function conductivity_effective(p::AbstractParam)
    """
    Effective conductivity [S/m]
    """
    ϵ_sp, ϵ_sn = active_material(p)

    σ_eff_p = p.θ[:σ_p]*ϵ_sp
    σ_eff_n = p.θ[:σ_n]*ϵ_sn

    return σ_eff_p, σ_eff_n
end

function surface_area_to_volume_ratio(p::AbstractParam)
    """
    Surface area to volume ratio for a sphere (SA/V = 4πr^2/(4/3πr^3)) multipled by the active material fraction [m^2/m^3]
    """
    ϵ_sp, ϵ_sn = active_material(p)

    a_p = 3ϵ_sp/p.θ[:Rp_p]
    a_n = 3ϵ_sn/p.θ[:Rp_n]

    return a_p, a_n
end

function coeff_reaction_rate(states, p::AbstractParam)
    """
    Reaction rates (k) of cathode and anode [m^2.5/(m^0.5 s)]
    """
    T = states[:T]
    c_s_avg = states[:c_s_avg]

    return p.numerics.rxn_rate(T.p, T.n, c_s_avg.p, c_s_avg.n, p)
end

function coeff_solid_diffusion_effective(states::Dict, p::AbstractParam)
    c_s_avg = states[:c_s_avg]
    T = states[:T]
    
    return p.numerics.D_s_eff(c_s_avg.p, c_s_avg.n, T.p, T.n, p)
end

function coeff_electrolyte_diffusion_effective(states::Dict, p::AbstractParam)
    c_e = states[:c_e]
    T = states[:T]
    
    return p.numerics.D_eff(c_e.p, c_e.s, c_e.n, T.p, T.s, T.n, p)
end

function calc_j(Y, p::AbstractParam)

    T_p = repeat([p.θ[:T₀]],p.N.p)
    T_n = repeat([p.θ[:T₀]],p.N.n)

    c_s_avg_p = Y[p.ind.c_s_avg.p]
    c_s_avg_n = Y[p.ind.c_s_avg.n]

    c_s_star_p = Y[p.ind.c_s_avg.p[p.N.r_p:p.N.r_p:p.N.r_p*p.N.p]]
    c_s_star_n = Y[p.ind.c_s_avg.n[p.N.r_n:p.N.r_n:p.N.r_n*p.N.n]]

    # Calculate the reaction rates
    k_p_eff, k_n_eff = p.numerics.rxn_rate(T_p, T_n, c_s_avg_p, c_s_avg_n, p)
    
    j_p_calc = p.numerics.rxn_p(c_s_star_p, Y[p.ind.c_e.p], T_p, Y[p.ind.Φ_s.p] .- Y[p.ind.Φ_e.p] .- p.numerics.OCV_p(c_s_star_p./p.θ[:c_max_p])[1], k_p_eff, p.θ[:λ_MHC_p], p.θ[:c_max_p], p)
    j_n_calc = p.numerics.rxn_n(c_s_star_n, Y[p.ind.c_e.n], T_n, Y[p.ind.Φ_s.n] .- Y[p.ind.Φ_e.n] .- p.numerics.OCV_n(c_s_star_n./p.θ[:c_max_n])[1], k_n_eff, p.θ[:λ_MHC_n], p.θ[:c_max_n], p)

    return [j_p_calc; j_n_calc]
end

"""
Calculations which are primarily used in `set_vars!`, denoted by the prefix `calc_`.
"""
function limiting_electrode(p::AbstractParam)
    θ = p.θ
    ϵ_sp, ϵ_sn = active_material(p)

    if ϵ_sp*θ[:l_p]*θ[:c_max_p]*(θ[:θ_min_p] - θ[:θ_max_p]) > ϵ_sn*θ[:l_n]*θ[:c_max_n]*(θ[:θ_max_n] - θ[:θ_min_n])
        return :p
    else
        return :n
    end
end

@inline calc_I1C(p::AbstractParam) = calc_I1C(p.θ)
@inline function calc_I1C(θ::Dict{Symbol,T}) where T<:Union{Float64,Any}
    """
    Calculate the 1C current density (A⋅hr/m²) based on the limiting electrode
    """
    F = 96485.3365

    ϵ_sp = 1.0 - (θ[:ϵ_fp] + θ[:ϵ_p])
    ϵ_sn = 1.0 - (θ[:ϵ_fn] + θ[:ϵ_n])

    I1C = (F/3600.0)*min(
        ϵ_sp*θ[:l_p]*θ[:c_max_p]*(θ[:θ_min_p] - θ[:θ_max_p]),
        ϵ_sn*θ[:l_n]*θ[:c_max_n]*(θ[:θ_max_n] - θ[:θ_min_n]),
        )

    return I1C
end

@inline function calc_SOC(c_s_avg::AbstractVector{Float64}, p::param)
    """
    Calculate the SOC (dimensionless fraction)
    """
    c_s_avg_sum = @views @inbounds mean(c_s_avg[(p.numerics.solid_diffusion === :Fickian ? p.N.p*p.N.r_p : p.N.p)+1:end])

    return (c_s_avg_sum/p.θ[:c_max_n] - p.θ[:θ_min_n])/(p.θ[:θ_max_n] - p.θ[:θ_min_n]) # cell-soc fraction
end

@inline function temperature_weighting(T::AbstractVector{<:Number},p::AbstractParam)
    @views @inbounds (
        mean(T[1:p.N.a])*p.θ[:l_a]+
        mean(T[1:p.N.p .+ (p.N.a)])*p.θ[:l_p]+
        mean(T[1:p.N.s .+ (p.N.a+p.N.p)])*p.θ[:l_s]+
        mean(T[1:p.N.n .+ (p.N.a+p.N.p+p.N.s)])*p.θ[:l_n]+
        mean(T[1:p.N.z .+ (p.N.a+p.N.p+p.N.s+p.N.n)])*p.θ[:l_z]
    )/(p.θ[:l_a]+p.θ[:l_p]+p.θ[:l_s]+p.θ[:l_n]+p.θ[:l_z])
end
@inline function constant_temperature(t,Y,YP::AbstractVector{<:Number},p::AbstractParam)
    temperature_weighting((@views @inbounds YP[p.ind.T]),p)
end
temperature_weighting(T::VectorOfArray,p::AbstractParam) = [temperature_weighting(_T,p) for _T in T]

η_plating(Y::AbstractVector{<:Number},p::AbstractParam) = @views @inbounds Y[p.ind.Φ_s.n[1]] - Y[p.ind.Φ_e.n[1]]
η_plating(t,Y,YP,p) = η_plating(Y,p)

export dc_s
dc_s(::Val{index}) where {index} = (t,Y,YP::AbstractVector{<:Number},p::AbstractParam)-> YP[p.ind.c_s_avg[index]]
dc_s(index::Int64) = dc_s(Val(index))