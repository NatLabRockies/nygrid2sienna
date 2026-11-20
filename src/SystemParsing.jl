using CSV
using DataFrames
using Dates
using TimeSeries
using InfrastructureSystems
using PowerSystems
const PSY = PowerSystems
const IS = InfrastructureSystems

include("parsing_utils.jl")

settings = _scenario_settings(ARGS)
scenario = settings.scenario
load_year = settings.weather_year
future = scenario != "historical-2019"
scenario_dir = joinpath("Data", "clcpa2040")
config_dir = future ? joinpath(scenario_dir, "config") : "config"
config_file(baseline, future_file) = joinpath(config_dir, future ? future_file : baseline)
if future
    include("clcpa2040.jl")
    scenario_inputs = CSV.read(settings.capacity_csv, DataFrame)
    capacity_configs = _allocate_capacity_configs(config_dir, scenario_inputs)
    load_scales = _scenario_load_scales(scenario_inputs)
end

base_power = 100
sys = PSY.System(base_power)
set_units_base_system!(sys, PSY.UnitSystem.NATURAL_UNITS)

df_bus = CSV.read(joinpath(config_dir, "bus_config.csv"), DataFrame)

##########################
##### ADD LOAD ZONE ######
##########################
zone_list = unique(df_bus[!, "zone"])
for zone in zone_list
    z = PSY.Area(zone, 0.0, 0.0)
    PSY.add_component!(sys, z)
end

##########################
##### ADD BUS ######
##########################
for (bus_id, bus) in enumerate(eachrow(df_bus))
    number = bus.busIdx
    name = bus.name * "_" * string(bus.Vn)
    bustype = bus.busType
    angle = bus.a0
    magnitude = bus.v0
    voltage_limits = (min=bus.vmin, max=bus.vmax)
    base_voltage = bus.Vn
    area = get_component(PSY.Area, sys, bus.zone)
    _build_bus(sys, number, name, bustype, angle, magnitude, voltage_limits, base_voltage, area)
end

##########################
##### ADD Transmission ###
##########################
df_branch = CSV.read(config_file("branch_config.csv", "branch_config_2040.csv"), DataFrame)
br_name_list = Set()
for (br_id, br) in enumerate(eachrow(df_branch))
    from_id = br.from
    to_id = br.to
    from_bus = first(get_components(x -> PSY.get_number(x) == from_id, ACBus, sys))
    to_bus = first(get_components(x -> PSY.get_number(x) == to_id, ACBus, sys))
    v1 = PSY.get_base_voltage(from_bus)
    v2 = PSY.get_base_voltage(to_bus)
    name = string(from_id) * "-" * string(to_id)
    if name in br_name_list
        println(name)
        name = name * "~2"
    end
    push!(br_name_list, name)
    r = br.r
    x = br.x
    b = br.b
    if br.rating_A != 0.0
        rating = br.rating_A
    else
        rating = 99999.0
    end
    if v1 == v2
        _build_lines(sys; frombus=from_bus, tobus=to_bus, name=name, r=r, x=x, b=b, rating=rating)
    else
        _build_transformers(sys; frombus=from_bus, tobus=to_bus, name=name, r=r, x=x, b=b, rating=rating)
    end
end

##########################
##### ADD DCline #########
##########################

df_hvdc = CSV.read(joinpath(config_dir, "hvdc_config.csv"), DataFrame)
for (hvdc_id, hvdc) in enumerate(eachrow(df_hvdc))
    name = hvdc.name
    from_id = hvdc.from_bus
    to_id = hvdc.to_bus
    from_bus = first(get_components(x -> PSY.get_number(x) == from_id, ACBus, sys))
    to_bus = first(get_components(x -> PSY.get_number(x) == to_id, ACBus, sys))
    rating = hvdc.Pmax
    _build_hvdc(sys; frombus=from_bus, tobus=to_bus, name=name, r=0.0, x=0.0, b=0.0, rating=rating)
end

##########################
### ADD InterfaceLimits ##
##########################
df_iflim = CSV.read(joinpath(config_dir, settings.interface_limits_file), DataFrame)
df_ifmap = CSV.read(config_file("interfaceflow_mapping.csv", "interfaceflow_mapping_2030.csv"), DataFrame)
for idx = 1:nrow(df_iflim)
    name = "IF_" * string(idx)
    rating_lb = df_iflim[df_iflim.index.==Int(idx), :rating_lb][1]
    rating_ub = df_iflim[df_iflim.index.==Int(idx), :rating_ub][1]
    setoflines = df_ifmap[df_ifmap.index.==Int(idx), :mapping]
    signofline = float(df_ifmap[df_ifmap.index.==Int(idx), :sign])
    ifdict = Dict(zip(string.(setoflines), signofline))
    _build_interface_flow(sys; name, rating_lb, rating_ub, ifdict)
end

##########################
### ADD Generators #######
##########################

pm_mapping = Dict(
    "Combustion Turbine" => PrimeMovers.CT,
    "Combined Cycle" => PrimeMovers.CC,
    "Internal Combustion" => PrimeMovers.IC,
    "Steam Turbine" => PrimeMovers.ST,
    "Jet Engine" => PrimeMovers.GT,
)

fuel_mapping = Dict(
    "Kerosene" => ThermalFuels.DISTILLATE_FUEL_OIL,
    "Natural Gas" => ThermalFuels.NATURAL_GAS,
    "Fuel Oil 2" => ThermalFuels.DISTILLATE_FUEL_OIL,
    "Coal" => ThermalFuels.COAL,
    "Fuel Oil 6" => ThermalFuels.RESIDUAL_FUEL_OIL,
)
#### Add Thermal #########
df_thermal = CSV.read(joinpath(config_dir, "thermal_config.csv"), DataFrame)
hours = get_timestamp(load_year)
price_hours = get_timestamp(2019)
price_indices = future ? _price_calendar_indices(hours) : eachindex(hours)
fuel_cost = CSV.read("Data/fuelPriceWeekly_2019.csv", DataFrame; dateformat=dateformat"mm/dd/yyyy")
fuel_week = _fuel_week_indices(fuel_cost.TimeStamp, price_hours)[price_indices]
retired = future ? Set(CSV.read(joinpath(config_dir, "retired_generators_2025.csv"), DataFrame).PTID) : Set()
for (th_id, th) in enumerate(eachrow(df_thermal))
    name = th.Name
    bus = first(get_components(x -> PSY.get_number(x) == th.BusId, ACBus, sys))
    fuel = fuel_mapping[th.FuelType]
    pmin = th.Pmin
    pmax = th.Pmax
    # if pmin == 0.0
    #     pmin = 0.2 * pmax ## TODO: find better way to estimate pmin
    # end
    price_column = _fuel_price_column(th.Zone, th.FuelType)
    startup_fuel_price = maximum(fuel_cost[!, price_column])
    heatrate1 = future ? round(th.HeatRateLM_1; digits=2) : th.HeatRateLM_1
    heatrate0 = future ? 0.0 : th.HeatRateLM_0
    op_cost = _add_thermal_cost(heatrate1, heatrate0, pmin, startup_fuel_price)
    ramp_rate = th.maxRamp10 / 10.0
    pm = pm_mapping[th.UnitType]
    generator = _add_thermal(sys, bus, name=name, fuel=fuel, cost=op_cost, pmin=pmin, pmax=pmax, ramp_rate=ramp_rate, pm=pm, available=!(th.PTID in retired))
    PSY.set_fuel_cost!(sys, generator, SingleTimeSeries("fuel_cost", TimeArray(hours, fuel_cost[fuel_week, price_column])))
end

##  Add Nuclear ##############
df_nuclear = CSV.read(config_file("nuclear_config.csv", "nuclear_config_2040.csv"), DataFrame)
nuclear_cf = CSV.read("Data/nuclearGenDaily_2019.csv", DataFrame)
for (th_id, th) in enumerate(eachrow(df_nuclear)) # TODO: nuclear maintainance not considered
    name = th.Name
    bus = first(get_components(x -> PSY.get_number(x) == th.BusId, ACBus, sys))
    fuel = ThermalFuels.NUCLEAR
    pmin = th.Pmin
    pmax = th.Pmax
    op_cost = ThermalGenerationCost(;
        variable=FuelCurve(; value_curve=LinearCurve(1.1), fuel_cost=1.0),
        fixed=0.0,
        start_up=0.0,
        shut_down=0.0,
    )
    ramp_rate = th.maxRamp10 / 10.0
    pm = PrimeMovers.ST
    generator = _add_nuclear(sys, bus, name=name, fuel=fuel, cost=op_cost, pmin=pmin, pmax=pmax, ramp_rate=ramp_rate, pm=pm)
end

##  Add Hydro ##############
df_hydro = CSV.read(config_file("hydro_config.csv", "hydro_config_2040.csv"), DataFrame)
if future
    _add_2040_hydro!(sys, df_hydro, scenario_dir, load_year, load_scales)
else
    for (hy_id, hy) in enumerate(eachrow(df_hydro))
        name = hy.Name
        bus = first(get_components(x -> PSY.get_number(x) == hy.BusId, ACBus, sys))
        pmin = hy.Pmin
        pmax = hy.Pmax
        op_cost = ThermalGenerationCost(;
            variable=FuelCurve(; value_curve=LinearCurve(3.0), fuel_cost=1.0),
            fixed=0.0,
            start_up=0.0,
            shut_down=0.0,
        )
        ramp_rate = hy.maxRamp10 / 10.0
        pm = PrimeMovers.HY
        generator = _add_hydro(sys, bus, name=name, cost=op_cost, pmin=pmin, pmax=pmax, ramp_rate=ramp_rate, pm=pm)
    end
end

##  Add AggGen ###########
zonename_mapping = Dict(
    "NEISO" => "NPX",
    "PJM" => "PJM",
    "IESO" => "O H",
    "HQ" => "H Q",
)
df_agg = CSV.read(joinpath(config_dir, "agggen_config.csv"), DataFrame)
df_hourlylmp = CSV.read("Data/priceHourly_2019.csv", DataFrame; dateformat=dateformat"mm/dd/yyyy HH:MM:SS")
zonal_prices = Dict(zone => _hourly_zonal_prices(df_hourlylmp, label, price_hours)[price_indices]
                    for (zone, label) in zonename_mapping)
for (th_id, th) in enumerate(eachrow(df_agg))
    name = th.Name
    bus = first(get_components(x -> PSY.get_number(x) == th.BusId, ACBus, sys))
    fuel = ThermalFuels.OTHER
    pmin = th.Pmin
    pmax = th.Pmax
    # if pmin == 0.0
    #     pmin = 0.2 * pmax ## TODO: find better way to estimate pmin
    # end
    zonal_price = zonal_prices[th.Zone]
    if name == "Hqimport"
        source = PSY.Source(;
            name=name,
            available=true,
            bus=bus,
            base_power=base_power,
            active_power_limits=(min=pmin / base_power, max=pmax / base_power),
        )
        PSY.add_component!(sys, source)
        import_offers = [PSY.PiecewiseStepData([0.0, Float64(pmax)], [price]) for price in zonal_price]
        export_offers = [PSY.PiecewiseStepData([0.0, Float64(-pmin)], [price]) for price in zonal_price]
        PSY.set_import_variable_cost!(sys, source,
            SingleTimeSeries("import_offer", TimeArray(hours, import_offers)), PSY.UnitSystem.NATURAL_UNITS)
        PSY.set_export_variable_cost!(sys, source,
            SingleTimeSeries("export_offer", TimeArray(hours, export_offers)), PSY.UnitSystem.NATURAL_UNITS)
        continue
    end
    op_cost = ThermalGenerationCost(;
        variable=FuelCurve(; value_curve=LinearCurve(1.0), fuel_cost=1.0),
        fixed=0.0,
        start_up=0.0,
        shut_down=0.0,
    )
    ramp_rate = th.maxRampAgc
    pm = PrimeMovers.OT
    generator = _add_thermal(sys, bus, name=name, fuel=fuel, cost=op_cost, pmin=pmin, pmax=pmax, ramp_rate=ramp_rate, pm=pm)
    PSY.set_fuel_cost!(sys, generator, SingleTimeSeries("fuel_cost", TimeArray(hours, zonal_price)))
end

##########################
### ADD Loads ############
##########################
if future
    _add_2040_profiles!(sys, scenario_dir, load_year, capacity_configs, load_scales)
else
    load_profile = CSV.read("Data/load_profiles.csv", DataFrame)
    for busid in names(load_profile)
        bus = first(get_components(x -> PSY.get_number(x) == parse(Float64, busid), ACBus, sys))
        name = "load_" * busid
        load_ts = load_profile[!, busid]
        # if minimum(load_ts) <= 0.0
        #     load_ts[load_ts.<=0.0] .= 0.1
        # end
        _build_load(sys, bus, name, load_ts, load_year)
    end
end

PSY.to_json(sys, settings.system_file, force=true)