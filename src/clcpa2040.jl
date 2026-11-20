function _price_calendar_indices(hours)
    start = DateTime(2019, 1, 1)
    return map(hours) do timestamp
        day = month(timestamp) == 2 && Dates.day(timestamp) == 29 ? 28 : Dates.day(timestamp)
        mapped = DateTime(2019, month(timestamp), day, Dates.hour(timestamp))
        Int(Dates.value(mapped - start) ÷ Dates.value(Millisecond(Hour(1)))) + 1
    end
end

function _expand_profile(values, year)
    if Dates.isleapyear(year) && length(values) == 8760
        values = vcat(values[1:1416], values[1393:1416], values[1417:end])
    end
    length(values) == length(get_timestamp(year)) ||
        throw(ArgumentError("Profile for $year has $(length(values)) hours"))
    return values
end

function _scenario_bus(sys, bus_id)
    return first(PSY.get_components(x -> PSY.get_number(x) == bus_id, PSY.ACBus, sys))
end

function _load_2040_profiles(scenario_dir, year)
    profiles = Dict{String, DataFrame}()
    for kind in ("Baseload", "ComLoad", "ResLoad", "EVload")
        filename = kind == "EVload" ? "EVload.csv" : "$(kind)_$(year).csv"
        profiles[kind] = CSV.read(joinpath(scenario_dir, "load_profile", kind, filename), DataFrame)
    end
    return profiles
end

function _scenario_load_scales(targets)
    zones = string.('A':'K')
    all(column -> column in names(targets), ["Tech"; zones; "LoadScale"]) ||
        throw(ArgumentError("Scenario CSV must have Tech, zones A through K, and LoadScale columns"))
    any(ismissing, targets.Tech) && throw(ArgumentError("Scenario CSV contains an empty technology"))
    return map(("Baseload", "ComLoad", "ResLoad", "EVload")) do kind
        indices = findall(==(kind), targets.Tech)
        length(indices) == 1 || throw(ArgumentError("Scenario CSV must contain exactly one $kind row"))
        value = targets[only(indices), :LoadScale]
        value isa Real && isfinite(value) && value >= 0 ||
            throw(ArgumentError("LoadScale for $kind must be a nonnegative finite number"))
        any(zone -> !ismissing(targets[only(indices), zone]), zones) &&
            throw(ArgumentError("Load scale $kind must not have zonal capacity values"))
        kind => Float64(value)
    end
end

function _allocate_capacity_configs(config_dir, targets)
    zones = string.('A':'K')
    all(column -> column in names(targets), ["Tech"; zones]) ||
        throw(ArgumentError("Capacity CSV must have Tech and zone columns A through K"))
    technologies = ("Wind_LBW", "Wind_OSW", "UPV", "DPV", "Storage")
    any(ismissing, targets.Tech) && throw(ArgumentError("Capacity CSV contains an empty technology"))
    for tech in technologies
        count(==(tech), targets.Tech) == 1 ||
            throw(ArgumentError("Capacity CSV must contain exactly one $tech row"))
    end
    unknown = setdiff(collect(skipmissing(targets.Tech)),
                      [technologies...; "ZCF"; "Baseload"; "ComLoad"; "ResLoad"; "EVload"])
    isempty(unknown) || throw(ArgumentError("Unsupported capacity technologies: $(join(unknown, ", "))"))
    buses = CSV.read(joinpath(config_dir, "bus_config.csv"), DataFrame)
    bus_zones = Dict(row.busIdx => row.zone for row in eachrow(buses))
    configs = Dict{String, DataFrame}()
    for kind in ("wind", "upv", "dpv", "storage")
        config = CSV.read(joinpath(config_dir, "$(kind)_config.csv"), DataFrame)
        config.zone = [get(bus_zones, row.BusId, missing) for row in eachrow(config)]
        any(ismissing, config.zone) && throw(ArgumentError("Missing bus zone in $(kind)_config.csv"))
        config.allocated_cap = zeros(nrow(config))
        configs[kind] = config
    end

    for (tech, kind, prefix, weight) in (
        ("Wind_LBW", "wind", "LBW_", :rating), ("Wind_OSW", "wind", "OSW_", :rating),
        ("UPV", "upv", "UPV_", :rating), ("DPV", "dpv", "DPV_", :rating),
        ("Storage", "storage", "Storage_", :PowerCap),
    )
        target = targets[findfirst(==(tech), targets.Tech), :]
        config = configs[kind]
        for zone in zones
            value = target[zone]
            if ismissing(value)
                @warn "Blank capacity treated as zero" technology=tech zone
                continue
            end
            value isa Real && isfinite(value) && value >= 0 ||
                throw(ArgumentError("Invalid capacity for $tech in zone $zone: $value"))
            iszero(value) && continue
            indices = findall(row -> row.zone == zone && startswith(row.name, prefix), eachrow(config))
            isempty(indices) && throw(ArgumentError("No sites for $tech in zone $zone"))
            weights = config[indices, weight]
            all(w -> w isa Real && isfinite(w) && w >= 0, weights) && sum(weights) > 0 ||
                throw(ArgumentError("Invalid site weights for $tech in zone $zone"))
            config.allocated_cap[indices] .= value .* weights ./ sum(weights)
        end
    end
    for config in values(configs)
        config.rating = config.allocated_cap
        select!(config, Not(:allocated_cap))
    end
    return configs
end

function _hydro_hourly_energy(quarter_energy, year; load_shape=nothing)
    length(quarter_energy) == 48 ||
        throw(ArgumentError("Expected 48 hydro energy values for $year"))
    result = zeros(length(get_timestamp(year)))
    index = 1
    for month_number in 1:12
        hours_in_month = Dates.daysinmonth(Date(year, month_number, 1)) * 24
        hours_per_quarter = hours_in_month ÷ 4
        for quarter in 1:4
            range = index:(index + hours_per_quarter - 1)
            energy = quarter_energy[(month_number - 1) * 4 + quarter]
            if isnothing(load_shape)
                result[range] .= energy / hours_per_quarter
            else
                weights = load_shape[range]
                total = sum(weights)
                total > 0 || throw(ArgumentError("Nonpositive Niagara load shape in $year month $month_number"))
                result[range] .= energy .* weights ./ total
            end
            index += hours_per_quarter
        end
    end
    return result
end

function _add_2040_hydro!(sys, hydro_config, scenario_dir, year, load_scales)
    profiles = _load_2040_profiles(scenario_dir, year)
    zone_a = zeros(length(get_timestamp(year)))
    for (kind, scale) in load_scales
        profile = profiles[kind]
        for bus in 54:61
            column = string(bus)
            if column in names(profile)
                zone_a .+= scale .* _expand_profile(profile[!, column], year)
            end
        end
    end
    niagara_data = CSV.read(joinpath(scenario_dir, "hydro", "nypaNiagaraEnergy.climate.change.csv"), DataFrame)
    stlawrence_data = CSV.read(joinpath(scenario_dir, "hydro", "nypaMosesSaundersEnergy.climate.change.csv"), DataFrame)
    niagara = _hydro_hourly_energy(niagara_data[niagara_data.Year .== year, "nypaNiagaraEnergy"], year; load_shape=zone_a)
    stlawrence = _hydro_hourly_energy(stlawrence_data[stlawrence_data.Year .== year, "nypaMosesSaundersEnergy"], year)
    for hy in eachrow(hydro_config)
        output = if hy.Name == "Robert Moses Niagara"
            niagara
        elseif hy.Name == "StLawrence"
            stlawrence
        else
            fill(hy.Pmax, length(get_timestamp(year)))
        end
        pmax = maximum(output)
        pmax > 0 || throw(ArgumentError("Nonpositive hydro capacity for $(hy.Name)"))
        hydro = PSY.HydroDispatch(;
            name=hy.Name, available=true, bus=_scenario_bus(sys, hy.BusId),
            active_power=pmax / base_power, reactive_power=0.0, rating=pmax / base_power,
            prime_mover_type=PSY.PrimeMovers.HY,
            active_power_limits=(min=hy.Pmin / base_power, max=pmax / base_power),
            reactive_power_limits=nothing,
            ramp_limits=(up=hy.maxRamp10 / 10 / base_power, down=hy.maxRamp10 / 10 / base_power),
            time_limits=(up=1.0, down=1.0), base_power=base_power,
            operation_cost=HydroGenerationCost(; variable=FuelCurve(; value_curve=LinearCurve(0.0), fuel_cost=1.0), fixed=0.0),
        )
        PSY.add_component!(sys, hydro)
        PSY.add_time_series!(sys, hydro, SingleTimeSeries(
            "max_active_power", TimeArray(get_timestamp(year), output ./ pmax);
            scaling_factor_multiplier=PSY.get_max_active_power,
        ))
    end
end

function _renewable_profile(path)
    raw = CSV.read(path, DataFrame; header=false)
    return DataFrame(permutedims(Matrix(select(raw, Not(:Column1)))),
                     Symbol.(string.(raw.Column1)); makeunique=true)
end

function _add_2040_profiles!(sys, scenario_dir, year, configs, load_scales)
    profiles = _load_2040_profiles(scenario_dir, year)
    labels = Dict("Baseload" => "Baseline_load_", "ComLoad" => "Comstock_load_",
                  "ResLoad" => "Resstock_load_", "EVload" => "EV_load_")
    for (kind, scale) in load_scales
        for column in names(profiles[kind])
            bus = _scenario_bus(sys, parse(Int, column))
            samples = _expand_profile(profiles[kind][!, column], year) .* scale
            _build_load(sys, bus, labels[kind] * column, samples, year)
        end
    end

    for (kind, filename, mover, dispatchable) in (
        ("wind", "Wind", PSY.PrimeMovers.WT, true),
        ("upv", "solarUPV", PSY.PrimeMovers.PVe, true),
        ("dpv", "solarDPV", PSY.PrimeMovers.PVe, false),
    )
        config = configs[kind]
        profiles = _renewable_profile(joinpath(scenario_dir, "$(kind)_profile", "$(filename)$(year)_cf.csv"))
        for row in eachrow(config)
            bus = _scenario_bus(sys, row.BusId)
            profile_name = kind == "wind" && startswith(row.name, "OSW") && row.BusId in (79, 80) ?
                "$(row.BusId)_1" : string(row.BusId)
            samples = _expand_profile(profiles[!, profile_name], year)
            common = (; name=row.name, available=true, bus=bus, active_power=row.rating / base_power,
                       reactive_power=0.0, rating=row.rating / base_power, prime_mover_type=mover,
                       power_factor=1.0, base_power=base_power)
            generator = if dispatchable
                PSY.RenewableDispatch(; common..., reactive_power_limits=(min=0.0, max=row.rating / base_power),
                    operation_cost=RenewableGenerationCost(; variable=CostCurve(; value_curve=LinearCurve(1.0))))
            else
                PSY.RenewableNonDispatch(; common...)
            end
            PSY.add_component!(sys, generator)
            PSY.add_time_series!(sys, generator, SingleTimeSeries(
                "max_active_power", TimeArray(get_timestamp(year), samples);
                scaling_factor_multiplier=PSY.get_max_active_power,
            ))
        end
    end

    _add_2040_storage!(sys, configs["storage"])
end

function _add_2040_storage!(sys, storage_config)
    for row in eachrow(storage_config)
        row.name != "PumpedHydro" && iszero(row.rating) && continue
        power, energy = if row.name == "PumpedHydro"
            (row.PowerCap, row.EnergyCap)
        else
            (row.rating, 8 * row.rating)
        end
        capacity = power / base_power
        storage = PSY.EnergyReservoirStorage(;
            name=row.name, available=true, bus=_scenario_bus(sys, row.BusId),
            prime_mover_type=PSY.PrimeMovers.BA, storage_technology_type=PSY.StorageTech.LIB,
            storage_capacity=energy / base_power, storage_level_limits=(min=0.0, max=1.0),
            initial_storage_capacity_level=0.0, rating=capacity, active_power=capacity,
            input_active_power_limits=(min=0.0, max=capacity),
            output_active_power_limits=(min=0.0, max=capacity), efficiency=(in=0.95, out=1.0),
            reactive_power=0.0, reactive_power_limits=nothing, base_power=base_power,
            operation_cost=StorageCost(; charge_variable_cost=CostCurve(LinearCurve(1.0))),
        )
        PSY.add_component!(sys, storage)
    end
end
