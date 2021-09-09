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
	run_reopt(m::JuMP.AbstractModel, fp::String)

Solve the model using the `Scenario` defined in JSON file stored at the file path `fp`.
"""
function run_reopt(m::JuMP.AbstractModel, fp::String)
	s = Scenario(JSON.parsefile(fp))
	run_reopt(m, REoptInputs(s))
end


"""
	run_reopt(m::JuMP.AbstractModel, d::Dict)

Solve the model using the `Scenario` defined in dict `d`.
"""
function run_reopt(m::JuMP.AbstractModel, d::Dict)
	s = Scenario(d)
	run_reopt(m, REoptInputs(s))
end


"""
	run_reopt(m::JuMP.AbstractModel, s::AbstractScenario)

Solve the model using a `Scenario` or `BAUScenario`.
"""
function run_reopt(m::JuMP.AbstractModel, s::AbstractScenario)
	run_reopt(m, REoptInputs(s))
end


"""
    run_reopt(t::Tuple{JuMP.AbstractModel, AbstractScenario})

Method for use with Threads when running BAU in parallel with optimal scenario.
"""
function run_reopt(t::Tuple{JuMP.AbstractModel, AbstractInputs})
	run_reopt(t[1], t[2])
end


"""
    run_reopt(ms::AbstractArray{T, 1}, fp::String) where T <: JuMP.AbstractModel

Solve the `Scenario` and `BAUScenario` in parallel using the first two (empty) models in `ms` and inputs defined in the
JSON file at the filepath `fp`.
"""
function run_reopt(ms::AbstractArray{T, 1}, fp::String) where T <: JuMP.AbstractModel
    d = JSON.parsefile(fp)
    run_reopt(ms, d)
end


"""
    run_reopt(ms::AbstractArray{T, 1}, d::Dict) where T <: JuMP.AbstractModel

Solve the `Scenario` and `BAUScenario` in parallel using the first two (empty) models in `ms` and inputs from `d`.
"""
function run_reopt(ms::AbstractArray{T, 1}, d::Dict) where T <: JuMP.AbstractModel
    s = Scenario(d)
    if !s.settings.run_bau
        @warn "Only using first Model and not running BAU case because Settings.run_bau == false."
	    results = run_reopt(ms[1], s)
        return results
    end

    run_reopt(ms, REoptInputs(s))
end


"""
    run_reopt(ms::AbstractArray{T, 1}, p::REoptInputs) where T <: JuMP.AbstractModel

Solve the `Scenario` and `BAUScenario` in parallel using the first two (empty) models in `ms` and inputs from `p`.
"""
function run_reopt(ms::AbstractArray{T, 1}, p::REoptInputs) where T <: JuMP.AbstractModel

    bau_inputs = BAUInputs(p)

    inputs = ((ms[1], bau_inputs), (ms[2], p))
    rs = Any[0, 0]
    Threads.@threads for i = 1:2
        rs[i] = run_reopt(inputs[i])
    end
    combine_results(rs[1], rs[2])
end


"""
	build_reopt!(m::JuMP.AbstractModel, fp::String)

Add variables and constraints for REopt model. 
`fp` is used to load in JSON file to construct REoptInputs.
"""
function build_reopt!(m::JuMP.AbstractModel, fp::String)
	s = Scenario(JSON.parsefile(fp))
	build_reopt!(m, REoptInputs(s))
	nothing
end


"""
	function build_reopt!(m::JuMP.AbstractModel, p::REoptInputs)
Add variables and constraints for REopt model.
"""
function build_reopt!(m::JuMP.AbstractModel, p::REoptInputs)

	add_variables!(m, p)

	for ts in p.time_steps_without_grid

		for tier in 1:p.s.electric_tariff.n_energy_tiers
			fix(m[:dvGridPurchase][ts, tier] , 0.0, force=true)
		end

		for t in p.s.storage.types
			fix(m[:dvGridToStorage][t, ts], 0.0, force=true)
		end

        if !isempty(p.s.electric_tariff.export_bins)
            for t in p.elec_techs, u in p.export_bins_by_tech[t]
                fix(m[:dvProductionToGrid][t, u, ts], 0.0, force=true)
            end
        end
	end

	for b in p.s.storage.types
		if p.s.storage.max_kw[b] == 0 || p.s.storage.max_kwh[b] == 0
			@constraint(m, [ts in p.time_steps], m[:dvStoredEnergy][b, ts] == 0)
			@constraint(m, m[:dvStorageEnergy][b] == 0)
			@constraint(m, m[:dvStoragePower][b] == 0)
			@constraint(m, [t in p.elec_techs, ts in p.time_steps_with_grid],
						m[:dvProductionToStorage][b, t, ts] == 0)
			@constraint(m, [ts in p.time_steps], m[:dvDischargeFromStorage][b, ts] == 0)
			@constraint(m, [ts in p.time_steps], m[:dvGridToStorage][b, ts] == 0)
		else
			add_storage_size_constraints(m, p, b)
			add_storage_dispatch_constraints(m, p, b)
		end
	end

	if !isempty(p.gentechs)
		add_fuel_burn_constraints(m,p)
		add_binGenIsOnInTS_constraints(m,p)
		add_gen_can_run_constraints(m,p)
		add_gen_rated_prod_constraint(m,p)
	end

	if any(max_kw->max_kw > 0, (p.s.storage.max_kw[b] for b in p.s.storage.types))
		add_storage_sum_constraints(m, p)
	end

	add_production_constraints(m, p)

	if !isempty(p.techs)
		add_tech_size_constraints(m, p)
	end

	add_load_balance_constraints(m, p)

	if !isempty(p.s.electric_tariff.export_bins)
		add_export_constraints(m, p)
	end

	if !isempty(p.s.electric_tariff.monthly_demand_rates)
		add_monthly_peak_constraint(m, p)
	end

	if !isempty(p.s.electric_tariff.tou_demand_ratchet_timesteps)
		add_tou_peak_constraint(m, p)
	end

	if !(p.s.electric_utility.allow_simultaneous_export_import) & !isempty(p.s.electric_tariff.export_bins)
		add_simultaneous_export_import_constraint(m, p)
	end

	if p.s.electric_tariff.n_energy_tiers > 1
		add_energy_tier_constraints(m, p)
	end

    if p.s.electric_tariff.demand_lookback_percent > 0
        add_demand_lookback_constraints(m, p)
    end

	@expression(m, TotalTechCapCosts, p.third_party_factor *
		  sum( p.cap_cost_slope[t] * m[:dvPurchaseSize][t] for t in setdiff(p.techs, p.segmented_techs) )
	)
    if !isempty(p.segmented_techs)
        @warn "adding binary variable(s) to model cost curves"
        add_cost_curve_vars_and_constraints(m, p)
        for t in p.segmented_techs  # cannot have this for statement in sum( ... for t in ...) ???
           TotalTechCapCosts += p.third_party_factor * (
                sum(p.cap_cost_slope[t][s] * m[Symbol("dvSegmentSystemSize"*t)][s] + 
                    p.seg_yint[t][s] * m[Symbol("binSegment"*t)][s] for s in p.n_segs_by_tech[t])
            )
        end
    end

    if !isempty(p.pbi_techs)
        @warn "adding binary variable(s) to model production based incentives"
        add_prod_incent_vars_and_constraints(m, p)
    else
        m[:TotalProductionIncentive] = 0
    end
	
	@expression(m, TotalStorageCapCosts, p.third_party_factor *
		sum(  p.s.storage.installed_cost_per_kw[b] * m[:dvStoragePower][b]
			+ p.s.storage.installed_cost_per_kwh[b] * m[:dvStorageEnergy][b] for b in p.s.storage.types )
	)
	
	@expression(m, TotalPerUnitSizeOMCosts, p.third_party_factor * p.pwf_om *
		sum( p.om_cost_per_kw[t] * m[:dvSize][t] for t in p.techs )
	)
	
    if !isempty(p.gentechs)
		m[:TotalPerUnitProdOMCosts] = @expression(m, p.third_party_factor * p.pwf_om *
			sum(p.s.generator.om_cost_per_kwh * p.hours_per_timestep *
			m[:dvRatedProduction][t, ts] for t in p.gentechs, ts in p.time_steps)
		)
		m[:TotalGenFuelCharges] = @expression(m, p.pwf_e *
			sum(m[:dvFuelUsage][t,ts] * p.s.generator.fuel_cost_per_gallon for t in p.gentechs, ts in p.time_steps)
		)
    else
		m[:TotalPerUnitProdOMCosts] = 0.0
		m[:TotalGenFuelCharges] = 0.0
	end

	add_elec_utility_expressions(m, p)

	if !isempty(p.s.electric_utility.outage_durations)
		add_dv_UnservedLoad_constraints(m,p)
		add_outage_cost_constraints(m,p)
		add_MG_production_constraints(m,p)
		add_MG_storage_dispatch_constraints(m,p)
		add_cannot_have_MG_with_only_PVwind_constraints(m,p)
		add_MG_size_constraints(m,p)
		
		if !isempty(p.gentechs)
			add_MG_fuel_burn_constraints(m,p)
			add_binMGGenIsOnInTS_constraints(m,p)
		else
			m[:ExpectedMGFuelUsed] = 0
			m[:ExpectedMGFuelCost] = 0
			@constraint(m, [s in p.s.electric_utility.scenarios, tz in p.s.electric_utility.outage_start_timesteps, ts in p.s.electric_utility.outage_timesteps],
				m[:binMGGenIsOnInTS][s, tz, ts] == 0
			)
		end
		
		if p.s.site.min_resil_timesteps > 0
			add_min_hours_crit_ld_met_constraint(m,p)
		end
	end

	#################################  Objective Function   ########################################
	@expression(m, Costs,
		# Capital Costs
		TotalTechCapCosts + TotalStorageCapCosts +

		# Fixed O&M, tax deductible for owner
		TotalPerUnitSizeOMCosts * (1 - p.s.financial.owner_tax_pct) +

		# Variable O&M, tax deductible for owner
		m[:TotalPerUnitProdOMCosts] * (1 - p.s.financial.owner_tax_pct) +

		# Total Generator Fuel Costs, tax deductible for offtaker
        m[:TotalGenFuelCharges] * (1 - p.s.financial.offtaker_tax_pct) +

		# Utility Bill, tax deductible for offtaker
		m[:TotalElecBill] * (1 - p.s.financial.offtaker_tax_pct) -

        # Subtract Incentives, which are taxable
		m[:TotalProductionIncentive] * (1 - p.s.financial.owner_tax_pct)
	);
	if !isempty(p.s.electric_utility.outage_durations)
		add_to_expression!(Costs, m[:ExpectedOutageCost] + m[:mgTotalTechUpgradeCost] + m[:dvMGStorageUpgradeCost] + m[:ExpectedMGFuelCost])
	end
    
	nothing
end


function run_reopt(m::JuMP.AbstractModel, p::REoptInputs; obj::Int=2)

	build_reopt!(m, p)

	if obj == 1
		@objective(m, Min, m[:Costs])
	elseif obj == 2  # Keep SOC high
		@objective(m, Min, m[:Costs] - sum(m[:dvStoredEnergy][:elec, ts] for ts in p.time_steps) /
									   (8760. / p.hours_per_timestep)
		)
	end

	@info "Model built. Optimizing..."
	tstart = time()
	optimize!(m)
	opt_time = round(time() - tstart, digits=3)
	if termination_status(m) == MOI.TIME_LIMIT
		status = "timed-out"
    elseif termination_status(m) == MOI.OPTIMAL
        status = "optimal"
    else
		status = "not optimal"
		@warn "REopt solved with " termination_status(m), ", returning the model."
		return m
	end
	@info "REopt solved with " termination_status(m)
	@info "Solving took $(opt_time) seconds."

	tstart = time()
	results = reopt_results(m, p)
	time_elapsed = time() - tstart
	@info "Total results processing took $(round(time_elapsed, digits=3)) seconds."
	results["status"] = status
	results["solver_seconds"] = opt_time
	return results
end


function add_variables!(m::JuMP.AbstractModel, p::REoptInputs)
	@variables m begin
		dvSize[p.techs] >= 0  # System Size of Technology t [kW]
		dvPurchaseSize[p.techs] >= 0  # system kW beyond existing_kw that must be purchased
		dvGridPurchase[p.time_steps, 1:p.s.electric_tariff.n_energy_tiers] >= 0  # Power from grid dispatched to meet electrical load [kW]
		dvRatedProduction[p.techs, p.time_steps] >= 0  # Rated production of technology t [kW]
		dvCurtail[p.techs, p.time_steps] >= 0  # [kW]
		dvProductionToStorage[p.s.storage.types, p.techs, p.time_steps] >= 0  # Power from technology t used to charge storage system b [kW]
		dvDischargeFromStorage[p.s.storage.types, p.time_steps] >= 0 # Power discharged from storage system b [kW]
		dvGridToStorage[p.s.storage.types, p.time_steps] >= 0 # Electrical power delivered to storage by the grid [kW]
		dvStoredEnergy[p.s.storage.types, 0:p.time_steps[end]] >= 0  # State of charge of storage system b
		dvStoragePower[p.s.storage.types] >= 0   # Power capacity of storage system b [kW]
		dvStorageEnergy[p.s.storage.types] >= 0   # Energy capacity of storage system b [kWh]
		dvPeakDemandTOU[p.ratchets, 1:p.s.electric_tariff.n_tou_demand_tiers] >= 0  # Peak electrical power demand during ratchet r [kW]
		dvPeakDemandMonth[p.months, 1:p.s.electric_tariff.n_monthly_demand_tiers] >= 0  # Peak electrical power demand during month m [kW]
		MinChargeAdder >= 0
	end

	if !isempty(p.gentechs)  # Problem becomes a MILP
		@warn """Adding binary variable to model gas generator. 
				 Some solvers are very slow with integer variables"""
		@variables m begin
			dvFuelUsage[p.gentechs, p.time_steps] >= 0 # Fuel burned by technology t in each time step
			binGenIsOnInTS[p.gentechs, p.time_steps], Bin  # 1 If technology t is operating in time step h; 0 otherwise
		end
	end

    if !isempty(p.s.electric_tariff.export_bins)
        @variable(m, dvProductionToGrid[p.elec_techs, p.s.electric_tariff.export_bins, p.time_steps] >= 0)
        
    end

	if !(p.s.electric_utility.allow_simultaneous_export_import) & !isempty(p.s.electric_tariff.export_bins)
		@warn """Adding binary variable to prevent simultaneous grid import/export. 
				 Some solvers are very slow with integer variables"""
		@variable(m, binNoGridPurchases[p.time_steps], Bin)
	end

	if !isempty(p.s.electric_utility.outage_durations) # add dvUnserved Load if there is at least one outage
		@warn """Adding binary variable to model outages. 
				 Some solvers are very slow with integer variables"""
		max_outage_duration = maximum(p.s.electric_utility.outage_durations)
		outage_timesteps = p.s.electric_utility.outage_timesteps
		tZeros = p.s.electric_utility.outage_start_timesteps
		S = p.s.electric_utility.scenarios
		# TODO: currently defining more decision variables than necessary b/c using rectangular arrays, could use dicts of decision variables instead
		@variables m begin # if there is more than one specified outage, there can be more othan one outage start time
			dvUnservedLoad[S, tZeros, outage_timesteps] >= 0 # unserved load not met by system
			dvMGProductionToStorage[p.techs, S, tZeros, outage_timesteps] >= 0 # Electricity going to the storage system during each timestep
			dvMGDischargeFromStorage[S, tZeros, outage_timesteps] >= 0 # Electricity coming from the storage system during each timestep
			dvMGRatedProduction[p.techs, S, tZeros, outage_timesteps]  # MG Rated Production at every timestep.  Multiply by ProdFactor to get actual energy
			dvMGStoredEnergy[S, tZeros, 0:max_outage_duration] >= 0 # State of charge of the MG storage system
			dvMaxOutageCost[S] >= 0 # maximum outage cost dependent on number of outage durations
			dvMGTechUpgradeCost[p.techs] >= 0
			dvMGStorageUpgradeCost >= 0
			dvMGsize[p.techs] >= 0
			
			dvMGFuelUsed[p.techs, S, tZeros] >= 0
			dvMGMaxFuelUsage[S] >= 0
			dvMGMaxFuelCost[S] >= 0
			dvMGCurtail[p.techs, S, tZeros, outage_timesteps] >= 0

			binMGStorageUsed, Bin # 1 if MG storage battery used, 0 otherwise
			binMGTechUsed[p.techs], Bin # 1 if MG tech used, 0 otherwise
			binMGGenIsOnInTS[S, tZeros, outage_timesteps], Bin
		end
	end
end
