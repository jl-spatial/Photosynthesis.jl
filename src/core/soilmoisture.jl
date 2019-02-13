abstract type AbstractSoilData end
abstract type AbstractDeficitSoilData <: AbstractSoilData end
abstract type AbstractContentSoilData <: AbstractDeficitSoilData end

" @Deficit mixin macro adds water deficit fields to a struct"
@mix @columns struct Deficit{T}
    smd1::T   | 1.0 | _ | _ | _ | _
    smd2::T   | 1.0 | _ | _ | _ | _
end

"@Content mixin macro adds water content fields to a struct"
@Deficit @mix struct Content{W}
    swmax::W  | 1.0 | _ | _ | _ | _
    swmin::W  | 0.0 | _ | _ | _ | _
end

"Soil water is measured as deficit"
@Deficit struct DeficitSoilData{} <: AbstractDeficitSoilData end
"Soil water is measured as volumetric content"
@Content struct ContentSoilData{} <: AbstractContentSoilData end
"Simulated soil volumetric content"
@Content struct SimulatedSoilData{} <: AbstractContentSoilData end
"Soil water is measured as water potential"
@columns struct PotentialSoilData{T} <: AbstractSoilData
    swpexp::T | 1.0 | _ | _ | _ | _
end
struct NoSoilData <: AbstractSoilData end


abstract type AbstractSoilMethod{T} end

@columns struct VolumetricSoilMethod{WC,R,D,T<:AbstractContentSoilData
                                            } <: AbstractSoilMethod{T}
    soildata::T  | ContentSoilData() | _ | _ | _ | _
    wc1::WC      | 0.5               | _ | Beta(2.0, 2.0) | _ | _
    wc2::WC      | 0.5               | _ | Beta(2.0, 2.0) | _ | _
    soilroot::R  | 0.5               | _ | _ | _ | _ # Not sure these are parameters
    soildepth::D | 0.5               | _ | _ | _ | _ # One must be a variable...
end

@default_kw struct ConstantSoilMethod{T<:NoSoilData} <: AbstractSoilMethod{T}
    soildata::T | NoSoilData()
end
@default_kw struct DeficitSoilMethod{T<:AbstractDeficitSoilData} <: AbstractSoilMethod{T}
    soildata::T | ContentSoilData()
end
@default_kw struct PotentialSoilMethod{T<:PotentialSoilData} <: AbstractSoilMethod{T}
    soildata::T | PotentialSoilData()
end



"""
Calculate the effect of soil water content on stomatal conductance

These methods dispatch on AbstractSoilMethod or AbstractSoilData types.
"""
function soilmoisture_conductance end

soilmoisture_conductance!(f::ConstantSoilMethod, v) = v.fsoil = 1.0

"Convert volumetric data to deficit"
soilmoisture_conductance!(f::DeficitSoilMethod{<:AbstractContentSoilData}, v) = begin
    s = f.soildata
    soilmoist = (s.swmax - v.soilmoist) / (s.swmax - s.swmin)
    v.fsoil = soilmoisture_conductance(s, soilmoist, v)
end

soilmoisture_conductance!(f::DeficitSoilMethod{<:DeficitSoilData}, v) = 
    v.fsoil = soilmoisture_conductance(f.soildata, v.soilmoist, v)

soilmoisture_conductance!(f::PotentialSoilMethod{<:PotentialSoilData}, v) = 
    v.fsoil = soilmoisture_conductance(f.soildata, v.soilmoist, v)

soilmoisture_conductance!(f::VolumetricSoilMethod{<:SimulatedSoilData}, v) =
    v.soilmoist = f.soilroot / f.soildepth # TODO fix this, where is fsoil set??

soilmoisture_conductance!(f::VolumetricSoilMethod{<:AbstractContentSoilData}, v) = begin
    # TODO: check in constructor f.wc1 > f.wc2 && error("error: wc1 needs to be smaller than wc2.")
    fsoil = -f.wc1 / (f.wc2 - f.wc1) + v.soilmoist / (f.wc2 - f.wc1)
    v.fsoil = max(min(fsoil, 1.0), 0.0)
end

"""
    soilmoisture_conductance(soil::PotentialSoilData, soilmoist, v)
Negative exponential function of soil water potential. 
"""
soilmoisture_conductance(soil::PotentialSoilData, soilmoist, v) = begin # Exponential relationship with potential: parameter = SWPEXP
    # TODO: default value for effect? 
    if soil.swpexp > zero(soil.swpexp)
        effect = exp((soil.swpexp/oneunit(soil.swpexp) * soilmoist/oneunit(soilmoist)))
    end
    return max(effect, zero(effect))
end

"""
    soilmoisture_conductance(soil::AbstractDeficitSoilData, soilmoist, v)
GranierLoustau 1994 Fs = 1 - a exp(b SMD) where SMD is soil
moisture deficit, dimless """
soilmoisture_conductance(soil::AbstractDeficitSoilData, soilmoist, v) = begin
    effect = 1.0

    # Exponential relationship with deficit: params SMD1, SMD2
    if soil.smd1 > zero(soil.smd1)
        effect = 1.0 - soil.smd1 / oneunit(soil.smd1) * exp(soil.smd2 * soilmoist / oneunit(soilmoist)^2)
    # Linear decline with increasing deficit: pUT SMD1 < 0, param SMD2
    elseif soil.smd2 > zero(soil.smd2)
        if oneunit(soilmoist) - soilmoist < soil.smd2
            effect = (oneunit(soilmoist) - soilmoist) / soil.smd2
        end
    end
    return max(effect, zero(effect))
end


abstract type AbstractPotentialDependence end

@columns struct LinearPotentialDependence{Pa} <: AbstractPotentialDependence 
    vpara::Pa | -300.0 | kPa | Gamma(10, 1/10) | (0.0, -2000.0) | _
    vparb::Pa | -100.0 | kPa | Gamma(10, 2/10) | (0.0, -2000.0) | _
end

@columns struct ZhouPotentialDependence{S,Ψ} <: AbstractPotentialDependence 
    s::S | 2.0  | MPa^-1 | Gamma(10, 1/10) | (0.4, 12.0)  | "sensitivity parameter indicating the steepness of the decline"
    ψ::Ψ | -1.0 | MPa    | Gamma(10, 2/10) | (-0.1, -4.0) | "reference value indicating the water potential at which f(Ψpd) decreases to half of its maximum value"
end

struct NoPotentialDependence{} <: AbstractPotentialDependence end   


"""
Dependance of assimilation on soil water potential (SWP).
Modifier function (return value between 0.0 and 1.0) 
"""
function soilwater_limit end

"""
    potential_dependence(f::NoPotentialDependence, v)
Returns 1.0
"""
potential_dependence(f::NoPotentialDependence, soilwaterpotential) = 1.0

"""
    potential_dependence(f::LinearPotentialDependence, v, p)
Simple linear dependance.
vpara is swp where vcmax is zero, vparb is swp where vcmax is one.
"""
potential_dependence(f::LinearPotentialDependence, soilwaterpotential) =
    if soilwaterpotential < f.vpara 
        0.0
    elseif soilwaterpotential > f.vparb 
        1.0
    else 
        (soilwaterpotential - f.vpara) / (f.vparb - f.vpara)
    end

"""
    potential_dependence(f::ZhouPotentialDependence, v, p)
Zhou, et al. Agricultural and Forest Meteorology. 2013.0
"""
potential_dependence(f::ZhouPotentialDependence, soilwaterpotential) = 
    (1 + exp(f.s * f.ψ)) / 
    (1 + exp(f.s * (f.ψ - soilwaterpotential)))
