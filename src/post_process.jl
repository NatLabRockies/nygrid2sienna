function save_to_csv(cont, model_name, save_dir=".")
    for (name, df) in cont
        CSV.write(joinpath(save_dir, "$(name)_$(model_name).csv"), df)
    end
end

function _restore_hqimport_cost!(expressions, variables, parameters)
    import_prices = "IncrementalPiecewiseLinearSlopeParameter__Source"
    export_prices = "DecrementalPiecewiseLinearSlopeParameter__Source"
    haskey(parameters, import_prices) && haskey(parameters, export_prices) || return
    hq_values(table) = Dict(row.DateTime => row.value for row in eachrow(table) if row.name == "Hqimport")
    bought = hq_values(variables["ActivePowerOutVariable__Source"])
    sold = hq_values(variables["ActivePowerInVariable__Source"])
    isempty(bought) && return
    buy_price = hq_values(parameters[import_prices])
    sell_price = hq_values(parameters[export_prices])
    # PSI's rolling update reports only the last offer direction. Hqimport has
    # one tranche in each direction and one-hour intervals.
    for row in eachrow(expressions["ProductionCostExpression__Source"])
        row.name == "Hqimport" || continue
        t = row.DateTime
        row.value = bought[t] * buy_price[t] - sold[t] * sell_price[t]
    end
    return
end

function export_results_csv(results, variable, stage, path)
    variables = variable
    aux_variables = PSI.read_realized_aux_variables(results)
    parameters = PSI.read_realized_parameters(results)
    duals = PSI.read_realized_duals(results)
    expressions = PSI.read_realized_expressions(results)
    _restore_hqimport_cost!(expressions, variables, parameters)

    save_to_csv(variables, stage, path)
    save_to_csv(parameters, stage, path)
    save_to_csv(duals, stage, path)
    save_to_csv(aux_variables, stage, path)
    save_to_csv(expressions, stage, path)
    return
end