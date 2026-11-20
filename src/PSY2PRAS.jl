using PowerSystems
using SiennaPRASInterface

const PSY = PowerSystems
sys = PSY.System("historical_2019.json")

sequential_monte_carlo = SequentialMonteCarlo(samples=2, seed=1)
shortfalls, = assess(sys, PSY.Area, sequential_monte_carlo, Shortfall())

lole = LOLE(shortfalls)
eue = EUE(shortfalls)
