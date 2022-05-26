# *********************************************************************************
# REopt, Copyright (c) 2019-2020, Alliance for Sustainable Energy, LLC.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification,
# are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this list
# of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice, this
# list of conditions and the following disclaimer in the documentation and/or other
# materials provided with the distribution.
#
# Neither the name of the copyright holder nor the names of its contributors may be
# used to endorse or promote products derived from this software without specific
# prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
# OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
# OF THE POSSIBILITY OF SUCH DAMAGE.
# *********************************************************************************
"""
    Thermosyphon
struct with inner constructor:
```julia
function Thermosyphon(;
    ambient_temp_degF::Array{<:Real,1} = Real[],
    ground_temp_degF::Real=25,
    passive_to_active_cutoff_temp_degF::Real=20,
    effective_conductance_btu_per_degF::Real=141,
    design_active_cooling_rate_btu_per_hour::Real=0.197, #TODO: change # to from kw to btu/hour
    COP_curve_points_ambient_temp_degF::Array{<:Real,1} = Real[], #ordered from lowest to highest temperature
    COP_curve_points_coefficient_of_performance_kw_per_kw::Array{<:Real,1} = Real[], #one-to-one with COP_curve_points_ambient_temp_degF
    structure_heat_to_ground_mmbtu_per_year::Real=5.9
)
```
"""
struct Thermosyphon <: AbstractTech
    min_annual_active_cooling_mmbtu
    min_monthly_active_cooling_mmbtu
    coefficient_of_performance_series_mmbtu_per_kwh
    active_cooling_rate_mmbtu_per_hour
    time_steps_can_actively_cool
    time_steps_passively_cooling
    # effective_conductance_btu_per_degF
    # design_active_cooling_rate_kw
    # structure_heat_to_ground_mmbtu_per_year

    function Thermosyphon(;
        ambient_temp_degF::Array{<:Real,1} = Real[],
        ground_temp_degF::Real=25,
        passive_to_active_cutoff_temp_degF::Real=20,
        effective_conductance_btu_per_degF::Real=141,
        fixed_active_cooling_rate_kw::Real=0.345, # average cooling rate from most recent data, was 0.197 kw
        COP_curve_points_ambient_temp_degF::Array{<:Real,1} = Real[],
        COP_curve_points_coefficient_of_performance_kw_per_kw::Array{<:Real,1} = Real[],
        structure_heat_to_ground_mmbtu_per_year::Real=5.9,
        latitude::Float64,
        longitude::Float64
        )

        # validate inputs
        invalid_args = String[]
        # TODO: enforce length of temp same as loa, or resample
        # if !(length(ambient_temp_degF))
        if !(0 <= effective_conductance_btu_per_degF)
            push!(invalid_args, "effective_conductance_btu_per_degF must satisfy 0 <= effective_conductance_btu_per_degF, got $(effective_conductance_btu_per_degF)")
        end
        if !(0 <= fixed_active_cooling_rate_kw)
            push!(invalid_args, "design_active_cooling_rate_kw must satisfy 0 <= design_active_cooling_rate_kw, got $(design_active_cooling_rate_kw)")
        end
        if !(0 <= structure_heat_to_ground_mmbtu_per_year)
            push!(invalid_args, "structure_heat_to_ground_mmbtu_per_year must satisfy 0 <= structure_heat_to_ground_mmbtu_per_year, got $(structure_heat_to_ground_mmbtu_per_year)")
        end
        if length(COP_curve_points_coefficient_of_performance_kw_per_kw) != length(COP_curve_points_ambient_temp_degF)
            push!(invalid_args, "COP_curve_points_coefficient_of_performance_kw_per_kw and COP_curve_points_ambient_temp_degF must be the same length, got $(length(COP_curve_points_coefficient_of_performance_kw_per_kw)) and $(length(COP_curve_points_ambient_temp_degF))")
        end
        if length(invalid_args) > 0
            error("Invalid argument values: $(invalid_args)")
        end

        if isempty(ambient_temp_degF)
            # TODO: replace placeholder with temp from PVwatts (convert from python code commented out below)
            # ambient_temp_degF = repeat([35,5,25,50,60,10,40,90,30,70,30,0],outer=730)
            # Call PVWatts for hourly dry-bulb outdoor air temperature
            ambient_temp_degF = ambient_temp(latitude, longitude)# .- 10
            #@info ambient_temp_degF
        end

        if fixed_active_cooling_rate_kw > 0
            mmbtu_in_kwh = 0.00341214

            # Calculate passive cooling (only for time steps T_amb < cutoff temp)
            passive_cooling = ((ground_temp_degF .- filter(t -> t <= passive_to_active_cutoff_temp_degF, ambient_temp_degF)) .* (effective_conductance_btu_per_degF / 1000000))
            # passive_cooling = ((ground_temp_degF .- replace(t -> t <= passive_to_active_cutoff_temp_degF ? ground_temp_degF : t, ambient_temp_degF)) .* (effective_conductance_btu_per_degF / 1000000))
            # @info sum(passive_cooling)
            # Calculate annual cooling requirement
            min_annual_active_cooling_mmbtu = max(0,structure_heat_to_ground_mmbtu_per_year - sum(passive_cooling))
            time_steps_monthly = monthly_timesteps(2022)
            min_monthly_active_cooling_mmbtu = zeros(12)
            for month in 1:12
                month_passive_cooling = sum((ground_temp_degF .- filter(t -> t <= passive_to_active_cutoff_temp_degF, [ambient_temp_degF[ts] for ts in time_steps_monthly[month]])) .* (effective_conductance_btu_per_degF / 1000000))
                # min_monthly_active_cooling_mmbtu[month] = min_annual_active_cooling_mmbtu/12 - month_passive_cooling
                min_monthly_active_cooling_mmbtu[month] = 0
            end
            # month_days = [(0,30), (31,58), (59,89), (90,119), (120,150), (151,180), (181,211), (212,242), (243,272), (273,303), (304,333), (334,364)]
            # for month in 1:length(month_days)
            #     month_ts_bounds = month_days[month] .* 24 .+ 1
            #     month_ts
            #     min_monthly_active_cooling_mmbtu[month] = structure_heat_to_ground_mmbtu_per_year/12 - sum(passive_cooling[])

            # Calculate COP timeseries: could also interpolate linearly outside where we have data
            if isempty(COP_curve_points_ambient_temp_degF)
                COP_curve_points_ambient_temp_degF = [46,52,63]
                COP_curve_points_coefficient_of_performance_kw_per_kw = [9,6,3]
            end
            coefficient_of_performance_series_mmbtu_per_kwh = zeros(length(ambient_temp_degF))
            for i in 1:length(coefficient_of_performance_series_mmbtu_per_kwh)
                temp = ambient_temp_degF[i] #< 45 ? 45 : ambient_temp_degF[i]
                curve_point_temp_is_LTOET = searchsortedfirst(COP_curve_points_ambient_temp_degF, temp)
                if curve_point_temp_is_LTOET == 1
                    coefficient_of_performance_series_mmbtu_per_kwh[i] = mmbtu_in_kwh * COP_curve_points_coefficient_of_performance_kw_per_kw[1]
                elseif curve_point_temp_is_LTOET > length(COP_curve_points_ambient_temp_degF)
                    coefficient_of_performance_series_mmbtu_per_kwh[i] = mmbtu_in_kwh * COP_curve_points_coefficient_of_performance_kw_per_kw[curve_point_temp_is_LTOET-1]
                else
                    coefficient_of_performance_series_mmbtu_per_kwh[i] = mmbtu_in_kwh * 
                            (COP_curve_points_coefficient_of_performance_kw_per_kw[curve_point_temp_is_LTOET] 
                              - (
                                    (COP_curve_points_ambient_temp_degF[curve_point_temp_is_LTOET] - temp)
                                    * (COP_curve_points_coefficient_of_performance_kw_per_kw[curve_point_temp_is_LTOET] - COP_curve_points_coefficient_of_performance_kw_per_kw[curve_point_temp_is_LTOET-1])
                                    / (COP_curve_points_ambient_temp_degF[curve_point_temp_is_LTOET] - COP_curve_points_ambient_temp_degF[curve_point_temp_is_LTOET-1])
                                )
                            )
                end
            end
            coefficient_of_performance_series_mmbtu_per_kwh = round.(coefficient_of_performance_series_mmbtu_per_kwh, digits=8)
            
            # Calculate const active cooling rate:
            active_cooling_rate_mmbtu_per_hour = mmbtu_in_kwh * fixed_active_cooling_rate_kw
            # alt: Calculate timeseries of what active cooling rate would be at that ambient temp:
            # active_cooling_rate_to_amb_temp_ratio_kw_per_degF = 0.005238984 #0.006375615
            # active_cooling_rate_mmbtu_per_hour = mmbtu_in_kwh * active_cooling_rate_to_amb_temp_ratio_kw_per_degF * ambient_temp_degF
           
            # Calculate timesteps where active cooling is and isn't possible:
            time_steps_can_actively_cool = findall(>(passive_to_active_cutoff_temp_degF), ambient_temp_degF)
            time_steps_passively_cooling = findall(<=(passive_to_active_cutoff_temp_degF), ambient_temp_degF)
        else
            min_annual_active_cooling_mmbtu = 0
            min_monthly_active_cooling_mmbtu = 0
            coefficient_of_performance_series_mmbtu_per_kwh = zeros(length(ambient_temp_degF))
            active_cooling_rate_mmbtu_per_hour = 0
            time_steps_can_actively_cool = Real[]
            time_steps_passively_cooling = Real[] #or all time steps?
        end

        new(
            min_annual_active_cooling_mmbtu,
            min_monthly_active_cooling_mmbtu,
            coefficient_of_performance_series_mmbtu_per_kwh,
            active_cooling_rate_mmbtu_per_hour,
            time_steps_can_actively_cool,
            time_steps_passively_cooling
        )
    end
end

function ambient_temp(latitude::Real, longitude::Real; timeframe="hourly")
    url = string("https://developer.nrel.gov/api/pvwatts/v6.json", "?api_key=", nrel_developer_key,
        "&lat=", latitude , "&lon=", longitude, 
        "&tilt=45&system_capacity=1&azimuth=180&module_type=0&array_type=0&losses=0.14&dc_ac_ratio=1.1&gcr=0.4&inv_eff=96&timeframe=", timeframe
    )
    try
        @info "Querying PVWatts for ambient temperature for thermosyphon"
        r = HTTP.get(url)
        response = JSON.parse(String(r.body))
        if r.status != 200
            error("Bad response from PVWatts: $(response["errors"])")
        end
        @info "PVWatts success."
        amb_temp_f = get(response["outputs"], "tamb", []) .* 1.8 .+ 32.0
        # watts = collect(get(response["outputs"], "ac", []) / 1000)  # scale to 1 kW system (* 1 kW / 1000 W)
        if length(amb_temp_f) != 8760
            @error "PVWatts did not return a valid ambient temperature. Got $amb_temp_f"
        end
        return amb_temp_f
    catch e
        @error "Error occurred when calling PVWatts: $e"
    end
end

"""
    monthly_timesteps(year::Int; time_steps_per_hour=1)

return Array{Array{Int64,1},1}, size = (12,)
"""
function monthly_timesteps(year::Int; time_steps_per_hour=1)
    a = Array[]
    i = 1
    for m in range(1, stop=12)
        n_days = daysinmonth(Date(string(year) * "-" * string(m)))
        stop = n_days * 24 * time_steps_per_hour + i - 1
        if m == 2 && isleapyear(year)
            stop -= 24 * time_steps_per_hour  # TODO support extra day in leap years?
        end
        steps = [step for step in range(i, stop=stop)]
        append!(a, [steps])
        i = stop + 1
    end
    return a
end