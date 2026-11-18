using Revise
using PowerSimulations
using PowerSystems
using Dates
using Logging
logger = PowerSystems.configure_logging(console_level=Logging.Info)
const PSI = PowerSimulations
const PSY = PowerSystems
using TimeSeries
using JuMP
using HiGHS
using StorageSystemsSimulations
using HydroPowerSimulations
using DataFrames
using CSV
using PlotlyLight
using PowerGraphics
const PG = PowerGraphics
# Include the parsing utilities script
include("parsing_utils.jl")
include("post_process.jl")
# Simulation setup parameters
sim_name = "test_case"

output_dir = "TestRun"
interval = 24
horizon = 48
steps = 364

# Check if the output directory exists, create if not
if !ispath(output_dir)
    mkpath(output_dir)
end

solver = optimizer_with_attributes(
    HiGHS.Optimizer,
    "mip_rel_gap" => 1e-3,
    "output_flag" => true,
    "time_limit" => 60.0,
    "threads" => 8,
)

if !@isdefined(sys)
    @info "Loading system from nys2019.json"
    sys = PSY.System("nys2019.json")
end

# Transform time series data for the specified horizon and interval
PSY.transform_single_time_series!(sys, Hour(horizon), Hour(interval))

# Create a unit commitment template using DC power flow model
template_uc = PSI.template_unit_commitment(; network=NetworkModel(PSI.PTDFPowerModel, use_slacks=false, PTDF_matrix=PTDF(sys)))
# template_uc = PSI.template_unit_commitment(; network=NetworkModel(PSI.CopperPlatePowerModel, use_slacks=false, PTDF_matrix=PTDF(sys)))
# Set device models for different components
set_device_model!(template_uc, ThermalStandard, ThermalBasicDispatch)
if !isnothing(PSY.get_component(PSY.Source, sys, "Hqimport"))
    # Equal import and export prices preserve the legacy linear cost on net interchange.
    set_device_model!(template_uc, DeviceModel(
        PSY.Source, PSI.ImportExportSourceModel;
        attributes=Dict("reservation" => false),
        time_series_names=Dict{Type{<:PSI.ParameterType}, String}(),
    ))
end
set_device_model!(template_uc, StandardLoad, StaticPowerLoad)
# set_device_model!(template_uc, GenericBattery, StorageDispatchWithReserves)
set_device_model!(template_uc, Transformer2W, StaticBranch)
set_device_model!(template_uc, Line, StaticBranch)
set_device_model!(template_uc, TwoTerminalGenericHVDCLine, HVDCTwoTerminalLossless)
# set_device_model!(template_uc, HydroDispatch, HydroDispatchRunOfRiver)
# set_device_model!(template_uc, RenewableDispatch, RenewableFullDispatch)
set_service_model!(template_uc, TransmissionInterface, ConstantMaxInterfaceFlow)

# Create simulation models
models = SimulationModels(
    decision_models=[
        DecisionModel(
            template_uc,
            sys,
            name="UC",
            optimizer=solver,
            initialize_model=false,
            optimizer_solve_log_print=true,
            check_numerical_bounds=true,
            warm_start=true,
            store_variable_names=true,
        ),
    ],
)

# Create a simulation sequence
sequence = SimulationSequence(models=models, ini_cond_chronology=InterProblemChronology())

# Create a simulation object
sim = Simulation(
    name="$(sim_name)",
    steps=steps,
    models=models,
    sequence=sequence,
    simulation_folder=output_dir,
    # initial_time=DateTime("2019-07-18T14:00:00")
)

# Build and execute the simulation
build!(sim)
execute!(sim, enable_progress_bar=true)

model = get_simulation_model(sim, :UC)
JuMP.write_to_file(model.internal.container.JuMPmodel, "model.lp")
results = SimulationResults(sim; ignore_status=true);
results_uc = get_decision_problem_results(results, "UC");
set_system!(results_uc, sys);
variables = PSI.read_realized_variables(results_uc)
export_results_csv(results_uc, variables, "ED", joinpath(results.path, "results"))
p = PG.plot_fuel_plotly(
    results_uc;
    curtailment=true,
    set_display=false,
    title="all_plants_case_dispatch", # saved plot will saved with the title as its name
    slacks=true,
    # generator_mapping_file="generator_mapping.yaml",
    # palette=PG.load_palette("color.yaml"),
    save=".",
    format="html"
);
