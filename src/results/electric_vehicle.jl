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
`ElectricStorage` results keys:
- `ev_to_evse_series_binary` The timesteps (1's) for which each EV is connected to which EVSE
- `on_site_techs_to_ev_series_kw` On-site techs charging EV
- `annual_on_site_techs_to_ev_charge_energy_kwh`
- `grid_to_ev_series_kw` The timesteps (1's) Grid charging EV
- `annual_grid_to_ev_charge_energy_kwh`
- `annual_total_to_ev_charge_energy_kwh`
"""
function add_electric_vehicle_results!(m::JuMP.AbstractModel, p::REoptInputs, d::Dict, b::String; _n="")
    # The ElectricVehicle dictionaries are already populated with electric_storage_results,
    # so just add the unique EV results to them

    d[b]["ev_to_evse_series_binary"] = [Int64[] for i in eachindex(p.s.evse.power_rating_kw)]
    for se in eachindex(p.s.evse.power_rating_kw)
        d[b]["ev_to_evse_series_binary"][se] = round.(value.(m[Symbol("binEVtoEVSE"*_n)][se, b, ts] for ts in p.time_steps), digits=0)
    end

    d[b]["on_site_techs_to_ev_series_kw"] = round.(value.(sum(m[Symbol("dvProductionToStorage"*_n)][b, t, ts] for t in p.techs.elec) for ts in p.time_steps), digits=3)
    d[b]["annual_on_site_techs_to_ev_charge_energy_kwh"] = round(sum(d[b]["on_site_techs_to_ev_series_kw"]), digits=1)
    d[b]["grid_to_ev_series_kw"] = round.(value.(m[Symbol("dvGridToStorage"*_n)][b, ts] for ts in p.time_steps), digits=3)
    d[b]["annual_grid_to_ev_charge_energy_kwh"] = round(sum(d[b]["grid_to_ev_series_kw"]), digits=1)
    d[b]["annual_total_to_ev_charge_energy_kwh"] = d[b]["annual_on_site_techs_to_ev_charge_energy_kwh"] + 
                                                    d[b]["annual_grid_to_ev_charge_energy_kwh"]

    nothing
end