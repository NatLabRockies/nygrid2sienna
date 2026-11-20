using PowerSystems
const PSY = PowerSystems

#Function to generate a time array with hourly timestamps for a given year
get_timestamp(year) = DateTime("$(year)-01-01T00:00:00"):Hour(1):DateTime("$(year)-12-31T23:55:00")

function _scenario_settings(args)
    any(arg -> startswith(arg, "--"), args) &&
        throw(ArgumentError("Load scales must be specified in the scenario CSV, not as command-line flags"))
    positional = args
    length(positional) <= 3 ||
        throw(ArgumentError("Usage: historical-2019 OR future_year [weather_year] scenario.csv"))
    scenario = isempty(positional) ? "historical-2019" : positional[1]
    scenario == "2019" && (scenario = "historical-2019")
    scenario_year = scenario == "historical-2019" ? nothing : tryparse(Int, scenario)
    scenario != "historical-2019" && (isnothing(scenario_year) || scenario_year < 2030) &&
        throw(ArgumentError("Scenario must be historical-2019 or a future year of 2030 or later"))
    scenario == "historical-2019" && length(positional) > 1 &&
        throw(ArgumentError("Weather year and scenario CSV are only supported for future scenarios"))
    scenario != "historical-2019" && length(positional) < 2 &&
        throw(ArgumentError("A scenario CSV is required: future_year [weather_year] scenario.csv"))
    weather_year = length(positional) == 3 ? tryparse(Int, positional[2]) : 2019
    isnothing(weather_year) && throw(ArgumentError("Weather year must be an integer"))
    scenario != "historical-2019" && !(1998 <= weather_year <= 2019) &&
        throw(ArgumentError("Future scenarios have weather profiles for 1998 through 2019"))
    capacity_csv = if scenario == "historical-2019"
        nothing
    else
        input = positional[end]
        endswith(lowercase(input), ".csv") ||
            throw(ArgumentError("A scenario CSV is required: future_year [weather_year] scenario.csv"))
        input
    end
    suffix = scenario != "historical-2019" ?
        "_" * replace(splitext(basename(capacity_csv))[1], r"[^A-Za-z0-9_-]" => "_") : ""
    system_file = scenario == "historical-2019" ? "historical_2019.json" :
        "nys$(scenario)_$(weather_year)$(suffix).json"
    interface_limits_file = scenario == "historical-2019" ? "interfaceflow_limits.csv" :
        scenario_year < 2040 ? "interfaceflow_limits_2030.csv" : "interfaceflow_limits_2040.csv"
    return (; scenario, weather_year, capacity_csv, system_file, interface_limits_file)
end


function _build_bus(sys, number, name, bustype, angle, magnitude, voltage_limits, base_voltage, area)
    bus = PSY.ACBus(
        number=number,
        name=name,
        available=true,
        bustype=bustype,
        angle=angle,
        magnitude=magnitude,
        voltage_limits=voltage_limits,
        base_voltage=base_voltage,
        area=area,
    )
    add_component!(sys, bus)
end

function _build_lines(sys; frombus::PSY.ACBus, tobus::PSY.ACBus, name, r, x, b, rating)
    # Create a new storage device of the specified type
    device = PSY.Line(
        name=name,
        available=true,
        active_power_flow=rating / 100.0,
        reactive_power_flow=0.0,
        arc=PSY.Arc(from=frombus, to=tobus),
        r=r,
        x=x,
        b=(from=b, to=b),
        rating=rating / 100.0,
        angle_limits=PSY.MinMax((-1.571 * 2, 1.571 * 2)),
    )
    PSY.add_component!(sys, device)
    return device
end


function _build_transformers(sys; frombus::PSY.ACBus, tobus::PSY.ACBus, name, r, x, b, rating)
    # Create a new storage device of the specified type
    device = PSY.Transformer2W(
        name=name,
        available=true,
        active_power_flow=rating / 100.0,
        reactive_power_flow=0.0,
        arc=PSY.Arc(from=frombus, to=tobus),
        r=r,
        x=x,
        primary_shunt=b,
        rating=rating / 100.0,
        base_power=base_power,
    )
    PSY.add_component!(sys, device)
    return device
end


function _build_hvdc(sys; frombus::PSY.ACBus, tobus::PSY.ACBus, name, r, x, b, rating)
    # Create a new storage device of the specified type
    device = PSY.TwoTerminalGenericHVDCLine(
        name=name,
        available=true,
        active_power_flow=rating / base_power,
        arc=PSY.Arc(from=frombus, to=tobus),
        active_power_limits_from=PSY.MinMax((-rating / base_power, rating / base_power)),
        active_power_limits_to=PSY.MinMax((-rating / base_power, rating / base_power)),
        reactive_power_limits_from=PSY.MinMax((-rating / base_power, rating / base_power)),
        reactive_power_limits_to=PSY.MinMax((-rating / base_power, rating / base_power)),
        loss=LinearCurve(0.0),
    )
    PSY.add_component!(sys, device)
    return device
end


function _build_interface_flow(sys; name, rating_lb, rating_ub, ifdict)
    # Create a new storage device of the specified type
    service = PSY.TransmissionInterface(
        name=name,
        available=true,
        active_power_flow_limits=PSY.MinMax((rating_lb / 100.0, rating_ub / 100.0)),
        violation_penalty=0.0,
        direction_mapping=ifdict
    )
    contri_devices = PSY.get_components(
        x -> haskey(ifdict, PSY.get_name(x)),
        ACBranch,
        sys,
    )
    PSY.add_service!(sys, service, contri_devices)
    return service
end
function _add_thermal(
    sys,
    bus::PSY.Bus;
    name,
    fuel::PSY.ThermalFuels,
    pmin,
    pmax,
    ramp_rate,
    cost::PSY.OperationalCost,
    pm::PSY.PrimeMovers,
    available=true,
)
    device = PSY.ThermalStandard(
        name=name,
        available=available,
        status=true,
        bus=bus,
        active_power=0.0,
        reactive_power=0.0,
        rating=pmax / base_power,
        active_power_limits=PSY.MinMax((pmin / base_power, pmax / base_power)),
        reactive_power_limits=nothing,
        ramp_limits=(up=ramp_rate / base_power, down=ramp_rate / base_power),
        operation_cost=cost,
        base_power=base_power,
        time_limits=(up=1.0, down=1.0),
        prime_mover_type=pm,
        fuel=fuel,
        time_at_status=999.0,
        ext=Dict{String,Any}(),
    )
    PSY.add_component!(sys, device)

    return device  # Return the newly created component
end

function _fuel_price_column(zone, fuel)
    if fuel == "Coal"
        return "coal_NY"
    elseif fuel == "Natural Gas"
        zone in ("F", "G", "H", "I") && return "NG_F2I"
        zone == "J" && return "NG_J"
        zone == "K" && return "NG_K"
        return "NG_A2E"
    elseif fuel == "Fuel Oil 2" || fuel == "Kerosene"
        return zone in ("F", "G", "H", "I", "J", "K") ? "FO2_DSNY" : "FO2_UPNY"
    elseif fuel == "Fuel Oil 6"
        return zone in ("F", "G", "H", "I", "J", "K") ? "FO6_DSNY" : "FO6_UPNY"
    end
    throw(ArgumentError("Unsupported thermal fuel: $fuel"))
end

function _fuel_week_indices(week_starts, hours)
    issorted(week_starts) && allunique(week_starts) ||
        throw(ArgumentError("Weekly fuel price dates must be sorted and unique"))
    return map(hours) do hour
        day = Date(hour)
        i = searchsortedlast(week_starts, day)
        i > 0 && day < week_starts[i] + Day(7) ||
            throw(ArgumentError("Missing weekly fuel price for $day"))
        i
    end
end

function _hourly_zonal_prices(price_table, zone, hours)
    rows = sort(filter(row -> row.ZoneName == zone &&
                             first(hours) <= row.TimeStamp <= last(hours), price_table),
                :TimeStamp)
    rows.TimeStamp == collect(hours) ||
        throw(ArgumentError("LBMP for $zone must contain exactly one price per modeled hour"))
    return rows.LBMP
end

function _add_thermal_cost(heatrate1, heatrate0, pmin, fuel_cost)
    fuel_curve = FuelCurve(; value_curve=LinearCurve(heatrate1, heatrate0), fuel_cost=fuel_cost)
    startup_cost = pmin * heatrate1 * fuel_cost
    op_cost = ThermalGenerationCost(;
        variable=fuel_curve,
        fixed=0.0,
        start_up=startup_cost,
        shut_down=0.0,
    )
    return op_cost
end

function _add_nuclear(
    sys,
    bus::PSY.Bus;
    name,
    fuel::PSY.ThermalFuels,
    pmin,
    pmax,
    ramp_rate,
    cost::PSY.OperationalCost,
    pm::PSY.PrimeMovers,
)
    device = PSY.ThermalStandard(
        name=name,
        available=true,
        status=true,
        bus=bus,
        active_power=0.0,
        reactive_power=0.0,
        rating=pmax / base_power,
        active_power_limits=PSY.MinMax((pmin / base_power, pmax / base_power)),
        reactive_power_limits=nothing,
        ramp_limits=(up=ramp_rate / base_power, down=ramp_rate / base_power),
        operation_cost=cost,
        base_power=base_power,
        time_limits=(up=1.0, down=1.0),
        prime_mover_type=pm,
        fuel=fuel,
        time_at_status=999.0,
        ext=Dict{String,Any}(),
    )
    PSY.add_component!(sys, device)

    return device  # Return the newly created component
end

function _add_hydro(
    sys,
    bus::PSY.Bus;
    name,
    pmin,
    pmax,
    ramp_rate,
    cost::PSY.OperationalCost,
    pm::PSY.PrimeMovers,
)
    device = PSY.ThermalStandard(
        name=name,
        available=true,
        bus=bus,
        status=true,
        active_power=pmax / base_power,
        reactive_power=0.0,
        rating=pmax / base_power,
        active_power_limits=PSY.MinMax((pmin / base_power, pmax / base_power)),
        reactive_power_limits=nothing,
        ramp_limits=(up=ramp_rate / base_power, down=ramp_rate / base_power),
        operation_cost=cost,
        base_power=base_power,
        time_limits=(up=1.0, down=1.0),
        prime_mover_type=pm,
        fuel=ThermalFuels.OTHER,
        ext=Dict{String,Any}(),
    )
    PSY.add_component!(sys, device)

    return device  # Return the newly created component
end
#Function builds a wind component in the pwoer system. it takes arguments such as the system ('sys'), the bus wheree the wind component is located ('bus::PYS.Bus), 
#the name of the wind component ('name'), its rating, time series data for wind genration ('re_ts') and the year for which the data is provided ('load_year')
function _build_wind(sys, bus::PSY.Bus, name, rating, re_ts, load_year)
    #creates wind component using "RenewableDispatch construcotr from PSY package
    wind = PSY.RenewableDispatch(
        name=name,  #set name of wind component            
        available=true, #marks component as available 
        bus=bus, #assigns bus to which wind component is connected 
        active_power=rating / 100.0, #sets the active power wind component base on its rating 
        reactive_power=0.0, #sets reative power of wind component to zero 
        rating=rating / 100.0, #sets rating of wind component 
        prime_mover_type=PSY.PrimeMovers.WT, #sets the prime mover type of wind turbine
        reactive_power_limits=(min=0.0, max=1.0 * rating / 100.0), #sets the reative power limits 
        power_factor=1.0, #sets the operation cost 
        operation_cost=TwoPartCost(nothing),
        base_power=100, #sets base power to 100 
    )
    # Add the wind component to the power system
    add_component!(sys, wind)

    # Add a time series for the maximum active power based on the input time series data
    if maximum(re_ts) == 0.0
        PSY.add_time_series!(
            sys,
            wind,
            PSY.SingleTimeSeries(
                "max_active_power",
                TimeArray(get_timestamp(load_year), re_ts),
                scaling_factor_multiplier=PSY.get_max_active_power,
            )
        )
    else

        PSY.add_time_series!(
            sys,
            wind,
            PSY.SingleTimeSeries(
                "max_active_power",
                TimeArray(get_timestamp(load_year), re_ts / maximum(re_ts)),
                scaling_factor_multiplier=PSY.get_max_active_power,
            )
        )
    end

    return wind  #return the newly created wind component
end

#Function builds a solar component in the power system. Takes similar arguments to wind function. 
function _build_solar(sys, bus::PSY.Bus, name, rating, re_ts, load_year)
    #creates solar component using the 'RenewableDispatch' constructor from the 'PSY' package 
    solar = PSY.RenewableDispatch(
        name=name,  #sets name of solar component             
        available=true,   #marks the component as available       
        bus=bus, # assigns bus to which the solar ompnent is connected
        active_power=rating / 100.0, # sets the active power of the solar component based on its rating 
        reactive_power=0.0, #sets reatie power of solar component to zero 
        rating=rating / 100.0, #sets rating of solar component 
        prime_mover_type=PSY.PrimeMovers.PVe, #sets the prime mover type as photovoltaic 
        reactive_power_limits=(min=0.0, max=1.0 * rating / 100.0), #sets the reactive power limits
        power_factor=1.0, #sets the power factor to 1
        operation_cost=TwoPartCost(VariableCost(0.139), 0.0), #sets the operation cost of the solar component 
        base_power=100, #sets the base power to 0 
    )
    #add the solar component to the power system
    add_component!(sys, solar)

    #add a time series for the maximum active power based on the input time series data
    if maximum(re_ts) == 0.0
        PSY.add_time_series!(
            sys,
            solar,
            PSY.SingleTimeSeries(
                "max_active_power",
                TimeArray(get_timestamp(load_year), re_ts),
                scaling_factor_multiplier=PSY.get_max_active_power,
            )
        )
    else
        PSY.add_time_series!(
            sys,
            solar,
            PSY.SingleTimeSeries(
                "max_active_power",
                TimeArray(get_timestamp(load_year), re_ts / maximum(re_ts)),
                scaling_factor_multiplier=PSY.get_max_active_power,
            )
        )
    end

    return solar  #return the newly created solar component
end

#Function builds a battery component in the power system. it takes arugments such as system, type of storage device ('::Type{T}), 
#the bus where the battery component is loacted, its name, energy capacity, rating and efficiency
function _build_battery(sys, ::Type{T}, bus::PSY.Bus, name, energy_capacity, rating, efficiency) where {T<:PSY.Storage}

    # Create a new storage device of the specified type
    device = T(
        name=name,                         # Set the name for the new component
        available=true,                    # Mark the component as available
        bus=bus,                           # Assign the bus to the component
        prime_mover_type=PSY.PrimeMovers.BA,    # Set the prime mover to Battery
        initial_energy=energy_capacity / 2,  # Set initial energy level
        state_of_charge_limits=(min=energy_capacity * 0.1, max=energy_capacity),  # Set state of charge limits
        rating=rating,                     # Set the rating
        active_power=rating,               # Set active power equal to rating
        input_active_power_limits=(min=0.0, max=rating),  # Set input active power limits
        output_active_power_limits=(min=0.0, max=rating),  # Set output active power limits
        efficiency=(in=efficiency / 10000, out=1.0),  # Set efficiency
        reactive_power=0.0,                # Set reactive power
        reactive_power_limits=nothing,      # No reactive power limits
        base_power=100.0,                    # Set base power
        operation_cost=StorageManagementCost(
            VariableCost(0.0),
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
        )
    )

    # Add the battery component to the power system
    PSY.add_component!(sys, device)

    return device  # Return the newly created battery component
end

#Function builds a load component in the power system. it takes arugments such as system, bus, name, load_ts and load_eyear, 
function _build_load(sys, bus::PSY.Bus, name, load_ts, load_year)
    min_load, max_load = extrema(load_ts)
    # Keep the sign of the largest-magnitude value to avoid a near-zero divisor.
    scale = abs(min_load) > abs(max_load) ? min_load : max_load
    normalized_load = load_ts ./ (iszero(scale) ? 1.0 : scale)

    load = PSY.StandardLoad(
        name=name,
        available=true,
        bus=bus,
        base_power=100.0,
        max_constant_active_power=scale / base_power,
    )

    # Add the load component to the power system model
    add_component!(sys, load)

    ### The issue was that the name of the time series and the name in the renewable config doesn't match. Now they matched but we should think about how to name things later to make it easier to track.
    PSY.add_time_series!(
        sys,
        load,
        PSY.SingleTimeSeries(
            "max_active_power",
            TimeArray(get_timestamp(load_year), normalized_load);
            scaling_factor_multiplier=PSY.get_max_active_power,
        ),
    )

    return load  # Return the newly created load component
end


