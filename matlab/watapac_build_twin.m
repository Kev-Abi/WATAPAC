function model = watapac_build_twin(varargin)
%WATAPAC_BUILD_TWIN  Build the WATAPAC digital twin in Simulink.
%
%   Six subsystems following the manuscript's Methodology, mirroring
%   watapac_plant stage for stage:
%
%     1  Rainfall Runoff     rational method, Yellow rainfall profile
%     2  Debris Filtration   per-type capture, blockage, bypass
%     3  Cascade Turbines    T1 and T2 modelled separately, own heads
%     4  Power Conversion    alternator, 3-phase rectifier, buck, cut-in
%     5  Battery And Load    LED latch, Pi and Arduino draw, net SOC
%     6  Sensor Emulation    what the MAX471 and the firmware would report
%
%   watapac_plant is the reference implementation. It is plain MATLAB, runs
%   without Simulink, and is covered by watapac_validate. If this model and
%   that function ever disagree, the function is right.
%
%   Usage
%       watapac_build_twin
%       watapac_build_twin('Params', watapac_twin_params('eta_turbine',0.15))
%       watapac_build_twin('Open', false, 'Save', false)
%
%   After building:  sim('watapac_twin'), then inspect the logged signals
%   sim_flow, sim_power, sim_battery, sim_led, sim_sensor, sim_energy.
%
%   WHAT CHANGED FROM APPENDIX D
%     - debris load 25 g, matching the Methodology (was 250 g, tenfold)
%     - StopTime 1000 s, matching a trial (was 600 s)
%     - the LED load is actually subtracted from the battery; in Appendix D
%       LedWatts was computed and left dangling, so the pack only ever charged
%     - EnergyKWh is logged; in Appendix D the paper's headline result was
%       computed and discarded
%     - one battery model, from the pack in Appendix A, instead of three
%       conflicting ones across the firmware, the server and the twin
%     - the 3-phase rectifier drop and the buck converter's input floor are
%       modelled, which is what reveals the charge path problem
%     - the Pi and Arduino are in the load budget
%     - a sensor emulation stage, so the model predicts the READING and not
%       just the physical quantity

opts = parseOptions(varargin);
P = opts.Params;
model = opts.ModelName;

assignin('base', 'P', P);

if bdIsLoaded(model); close_system(model, 0); end
existing = which([model '.slx']);
if ~isempty(existing); delete(existing); end

fprintf('\n=== WATAPAC digital twin ===\n');
new_system(model);
guard = onCleanup(@() closeIfIncomplete(model));

%% ---- Rainfall profile --------------------------------------------------
% A full trial at the calibrated Yellow intensity, with a dry lead-in and
% tail so the LED hold logic and the rectifier cut-in are both exercised.
t_trial = P.trial_seconds;
rain_t = [0  30  31           t_trial+30    t_trial+31   t_trial+120]';
rain_v = [0   0  P.rain_yellow_mmh P.rain_yellow_mmh  0   0          ]';
rain_ts = timeseries(rain_v, rain_t);
assignin('base', 'rain_ts', rain_ts);
stop_time = t_trial + 120;

%% ---- Top level ---------------------------------------------------------
addb(model, 'simulink/Sources/From Workspace', 'Rainfall', [40 60 150 100], ...
    'VariableName', 'rain_ts', 'SampleTime', '0');
addb(model, 'simulink/Sources/Constant', 'DebrisLoad', [40 160 150 200], ...
    'Value', 'P.debris_total_g');

% --- live inputs, written once a second by watapac_live ----------------
% Constant blocks, because a Constant's Value is tunable in Normal mode:
% set_param can change it while the simulation runs, which is what makes
% the twin track the prototype. They hold their last value if the Pi goes
% quiet, so the Scope flatlines rather than dropping to zero.
live = { 'Flow_In',       '0', [40 520 150 560]
         'T1_Measured',   '0', [40 590 150 630]
         'T2_Measured',   '0', [40 660 150 700]
         'Batt_Measured', '0', [40 730 150 770] };
for i = 1:size(live,1)
    addb(model, 'simulink/Sources/Constant', live{i,1}, live{i,3}, 'Value', live{i,2});
end

subs = { 'Rainfall Runoff',  [230  40 370 120]
         'Debris Filtration',[230 160 370 260]
         'Cascade Turbines', [440  40 590 140]
         'Power Conversion', [660  40 810 180]
         'Battery And Load', [880 160 1030 300]
         'Sensor Emulation', [660 300 810 420]
         'Live Comparison',  [880 520 1030 700] };
for i = 1:size(subs,1)
    add_block('built-in/Subsystem', [model '/' subs{i,1}], 'Position', subs{i,2});
end

buildRunoff(model);
buildFiltration(model);
buildTurbines(model);
buildConversion(model);
buildBatteryLoad(model);
buildSensors(model);
buildLiveComparison(model);

% --- choose what drives the turbines -----------------------------------
% Double-click the switch to flip between the simulated rainfall chain and
% the live flow arriving from the Pi. Both paths exist at once so the twin
% can be demonstrated with or without hardware attached.
addb(model, 'simulink/Math Operations/Gain', 'LiveFlowToCMS', [200 520 300 560], ...
    'Gain', '1/60000');
addb(model, 'simulink/Signal Routing/Manual Switch', 'FlowSource', [420 170 460 230]);

% --- logging. Every stage output is logged; Appendix D logged three. ---
logs = { 'LogFlow',    'sim_flow',    [1100  40]
         'LogPower',   'sim_power',   [1100 100]
         'LogEnergy',  'sim_energy',  [1100 160]
         'LogBattery', 'sim_battery', [1100 220]
         'LogLed',     'sim_led',     [1100 280]
         'LogSensor',  'sim_sensor',  [1100 340]
         'LogLive',    'sim_live',    [1100 520] };
for i = 1:size(logs,1)
    pos = [logs{i,3}(1) logs{i,3}(2) logs{i,3}(1)+80 logs{i,3}(2)+40];
    addb(model, 'simulink/Sinks/To Workspace', logs{i,1}, pos, ...
        'VariableName', logs{i,2}, 'SaveFormat', 'Structure With Time');
end

wire(model, 'Rainfall/1',          'Rainfall Runoff/1');
wire(model, 'Rainfall Runoff/1',   'Debris Filtration/1');
wire(model, 'DebrisLoad/1',        'Debris Filtration/2');
wire(model, 'Flow_In/1',           'LiveFlowToCMS/1');
wire(model, 'Debris Filtration/1', 'FlowSource/1');   % simulated path
wire(model, 'LiveFlowToCMS/1',     'FlowSource/2');   % live path
wire(model, 'FlowSource/1',        'Cascade Turbines/1');
wire(model, 'Cascade Turbines/1',  'Power Conversion/1');   % shaft power, W
wire(model, 'Debris Filtration/3', 'Power Conversion/2');   % Q to turbine, L/min
wire(model, 'Power Conversion/3',  'Battery And Load/1');   % charge power, W
wire(model, 'Rainfall Runoff/2',   'Battery And Load/2');   % Q, L/min
wire(model, 'Rainfall/1',          'Battery And Load/3');   % rain intensity
wire(model, 'Power Conversion/2',  'Sensor Emulation/1');   % true current, A
wire(model, 'Power Conversion/1',  'Sensor Emulation/2');   % bus volts

wire(model, 'Power Conversion/4',  'Live Comparison/1');    % predicted W
wire(model, 'T1_Measured/1',       'Live Comparison/2');
wire(model, 'T2_Measured/1',       'Live Comparison/3');

wire(model, 'Rainfall Runoff/2',   'LogFlow/1');
wire(model, 'Power Conversion/4',  'LogPower/1');
wire(model, 'Power Conversion/5',  'LogEnergy/1');
wire(model, 'Battery And Load/1',  'LogBattery/1');
wire(model, 'Battery And Load/2',  'LogLed/1');
wire(model, 'Sensor Emulation/1',  'LogSensor/1');
wire(model, 'Live Comparison/3',   'LogLive/1');

%% ---- Solver ------------------------------------------------------------
% ode23t is stiff-capable and handles the switching in the rectifier cut-in
% and the LED latch without the step-size collapse a non-stiff solver hits.
set_param(model, 'Solver', 'ode23t', 'StopTime', num2str(stop_time), ...
    'RelTol', '1e-4', 'MaxStep', '0.5');

try
    Simulink.BlockDiagram.arrangeSystem(model);
catch
end

fprintf('  stop time   : %g s (%g s trial + lead-in and tail)\n', stop_time, t_trial);
fprintf('  debris load : %g g\n', P.debris_total_g);
fprintf('  rainfall    : %g mm/h\n', P.rain_yellow_mmh);

if opts.Save
    target = fullfile(fileparts(mfilename('fullpath')), [model '.slx']);
    save_system(model, target);
    fprintf('  saved       : %s\n', target);
end
if opts.Open; open_system(model); end
clear guard;

fprintf('\n  Run it:   out = sim(''%s'');\n', model);
fprintf('  Compare:  watapac_validate\n\n');
end


%% ========================================================================
%  1. RAINFALL -> RUNOFF
%  ========================================================================
function buildRunoff(model)
s = [model '/Rainfall Runoff'];
openSubsystem(s, 'RainIntensity');

% Rational method: Q = C * i * A / 3.6e6, i in mm/h, A in m^2.
%
% A_catch_eff is the TEST catchment, back-calculated from the measured flow.
% Appendix D used a 1200 m^2 street catchment and then applied Froude
% scaling to it, which models a full-size inlet and cannot be compared
% against a bench measurement. The two are kept apart here.
addb(s, 'simulink/Math Operations/Gain', 'RationalMethod', [160 90 260 130], ...
    'Gain', 'P.C_runoff * P.A_catch_eff / 3.6e6');
addb(s, 'simulink/Math Operations/Gain', 'ToLPM', [330 170 400 210], 'Gain', '60000');

addb(s, 'simulink/Sinks/Out1', 'Q_cms', [470 103 500 117], 'Port', '1');
addb(s, 'simulink/Sinks/Out1', 'Q_lpm', [470 183 500 197], 'Port', '2');

wire(s, 'RainIntensity/1',  'RationalMethod/1');
wire(s, 'RationalMethod/1', 'Q_cms/1');
wire(s, 'RationalMethod/1', 'ToLPM/1');
wire(s, 'ToLPM/1',          'Q_lpm/1');
end


%% ========================================================================
%  2. TWO-STAGE FILTRATION
%  ========================================================================
function buildFiltration(model)
s = [model '/Debris Filtration'];
openSubsystem(s, 'Q_in');
addb(s, 'simulink/Sources/In1', 'DebrisMass', [40 240 70 254], 'Port', '2');

% Capture is weighted by the leaves/plastic split from the Methodology,
% not a single lumped efficiency.
addb(s, 'simulink/Math Operations/Gain', 'CaptureWeighted', [150 230 300 270], ...
    'Gain', ['(P.debris_leaves_g*P.capture_leaves + ' ...
             'P.debris_plastic_g*P.capture_plastic) / P.debris_total_g']);

% Blockage from retained debris. Bounded by the null result in Table 4.
addb(s, 'simulink/Math Operations/Gain', 'BlockageRate', [350 310 450 350], ...
    'Gain', 'P.blockage_per_g');
addb(s, 'simulink/Discontinuities/Saturation', 'BlockageLimit', [490 310 560 350], ...
    'UpperLimit', 'P.blockage_max', 'LowerLimit', '0');
addb(s, 'simulink/Sources/Constant', 'One', [490 230 550 270], 'Value', '1');
addb(s, 'simulink/Math Operations/Sum', 'OpenFraction', [610 250 640 280], 'Inputs', '+-');

addb(s, 'simulink/Math Operations/Product', 'Q_turbine', [700 90 740 130]);
addb(s, 'simulink/Math Operations/Gain', 'TurbToLPM', [790 170 860 210], 'Gain', '60000');

addb(s, 'simulink/Sinks/Out1', 'Q_t_cms',    [900 103 930 117], 'Port', '1');
addb(s, 'simulink/Sinks/Out1', 'DebrisCaught',[900 253 930 267], 'Port', '2');
addb(s, 'simulink/Sinks/Out1', 'Q_t_lpm',    [900 183 930 197], 'Port', '3');
addb(s, 'simulink/Sinks/Out1', 'Blockage',   [900 323 930 337], 'Port', '4');

wire(s, 'DebrisMass/1',      'CaptureWeighted/1');
wire(s, 'CaptureWeighted/1', 'DebrisCaught/1');
wire(s, 'CaptureWeighted/1', 'BlockageRate/1');
wire(s, 'BlockageRate/1',    'BlockageLimit/1');
wire(s, 'One/1',             'OpenFraction/1');
wire(s, 'BlockageLimit/1',   'OpenFraction/2');
wire(s, 'BlockageLimit/1',   'Blockage/1');
wire(s, 'Q_in/1',            'Q_turbine/1');
wire(s, 'OpenFraction/1',    'Q_turbine/2');
wire(s, 'Q_turbine/1',       'Q_t_cms/1');
wire(s, 'Q_turbine/1',       'TurbToLPM/1');
wire(s, 'TurbToLPM/1',       'Q_t_lpm/1');
end


%% ========================================================================
%  3. CASCADE TURBINES - T1 and T2 modelled separately
%  ========================================================================
function buildTurbines(model)
s = [model '/Cascade Turbines'];
openSubsystem(s, 'Q_cms');

% Each runner sees the full flow but only its share of the head. That is
% the cascade claim in the Discussion, and it is why the measured outputs
% were within 1.4 % of each other. Modelling them as one lumped turbine,
% as Appendix D does, cannot show that.
addb(s, 'simulink/Math Operations/Gain', 'T1_Hydraulic', [160 60 280 100], ...
    'Gain', 'P.rho * P.g * P.head_total_m * P.head_split(1)');
addb(s, 'simulink/Math Operations/Gain', 'T2_Hydraulic', [160 160 280 200], ...
    'Gain', 'P.rho * P.g * P.head_total_m * P.head_split(2)');

addb(s, 'simulink/Math Operations/Gain', 'T1_Runner', [330 60 450 100], ...
    'Gain', 'P.eta_turbine');
addb(s, 'simulink/Math Operations/Gain', 'T2_Runner', [330 160 450 200], ...
    'Gain', 'P.eta_turbine');

addb(s, 'simulink/Math Operations/Sum', 'ShaftTotal', [520 105 550 135], 'Inputs', '++');

addb(s, 'simulink/Sinks/Out1', 'ShaftW',   [620 113 650 127], 'Port', '1');
addb(s, 'simulink/Sinks/Out1', 'T1_ShaftW',[620  73 650  87], 'Port', '2');
addb(s, 'simulink/Sinks/Out1', 'T2_ShaftW',[620 173 650 187], 'Port', '3');

wire(s, 'Q_cms/1',       'T1_Hydraulic/1');
wire(s, 'Q_cms/1',       'T2_Hydraulic/1');
wire(s, 'T1_Hydraulic/1','T1_Runner/1');
wire(s, 'T2_Hydraulic/1','T2_Runner/1');
wire(s, 'T1_Runner/1',   'ShaftTotal/1');
wire(s, 'T2_Runner/1',   'ShaftTotal/2');
wire(s, 'T1_Runner/1',   'T1_ShaftW/1');
wire(s, 'T2_Runner/1',   'T2_ShaftW/1');
wire(s, 'ShaftTotal/1',  'ShaftW/1');
end


%% ========================================================================
%  4. ALTERNATOR -> RECTIFIER -> BUCK
%  ========================================================================
function buildConversion(model)
s = [model '/Power Conversion'];
openSubsystem(s, 'ShaftW');
addb(s, 'simulink/Sources/In1', 'Q_lpm', [40 300 70 314], 'Port', '2');

addb(s, 'simulink/Math Operations/Gain', 'Alternator', [150 90 260 130], ...
    'Gain', 'P.eta_generator');

% Open-circuit AC, then the 3-phase bridge. Two diodes conduct at any
% instant. Appendix D has no rectifier at all, so its bus voltage is
% 1.4 V too high and output is linear in flow right down to zero.
addb(s, 'simulink/Math Operations/Gain', 'OpenCircuitAC', [150 290 260 330], ...
    'Gain', 'P.kv_ac_per_lpm');
addb(s, 'simulink/Math Operations/Gain', 'BridgeRatio', [300 290 410 330], ...
    'Gain', 'P.rect_ac_to_dc');
addb(s, 'simulink/Math Operations/Bias', 'DiodeDrop', [450 290 520 330], ...
    'Bias', '-P.rect_v_drop');
addb(s, 'simulink/Discontinuities/Saturation', 'BusFloor', [560 290 630 330], ...
    'UpperLimit', 'inf', 'LowerLimit', '0');

% Below the diode drop nothing conducts. A real cut-in threshold.
addb(s, 'simulink/Sources/Constant', 'CutIn', [300 390 410 430], ...
    'Value', 'P.rect_v_drop');
addb(s, 'simulink/Logic and Bit Operations/Relational Operator', 'Conducting', ...
    [450 380 490 420], 'Operator', '>');

% Current = AC power / AC bus volts, guarded against divide-by-zero.
addb(s, 'simulink/Sources/Constant', 'VFloor', [450 180 510 220], 'Value', '0.1');
addb(s, 'simulink/Math Operations/MinMax', 'GuardV', [560 170 610 210], ...
    'Function', 'max', 'Inputs', '2');
addb(s, 'simulink/Math Operations/Divide', 'RawCurrent', [670 90 710 130], ...
    'Inputs', '*/');
addb(s, 'simulink/Math Operations/Product', 'GateCurrent', [760 90 800 130]);

% The bridge costs rect_v_drop volts AND rect_v_drop * I watts.
addb(s, 'simulink/Math Operations/Gain', 'RectLoss', [760 200 830 240], ...
    'Gain', 'P.rect_v_drop');
addb(s, 'simulink/Math Operations/Sum', 'DCPower', [880 100 910 130], 'Inputs', '+-');
addb(s, 'simulink/Discontinuities/Saturation', 'DCFloor', [950 95 1010 135], ...
    'UpperLimit', 'inf', 'LowerLimit', '0');

% The XL4015 is a step-down converter. It needs an input above both its own
% minimum and the pack voltage plus dropout. If it does not have one, no
% charge reaches the battery -- which is what this gate makes visible.
addb(s, 'simulink/Sources/Constant', 'BuckVinReq', [950 430 1080 470], ...
    'Value', 'max(P.buck_vin_min, P.batt_v_full + P.buck_dropout_v)');
addb(s, 'simulink/Logic and Bit Operations/Relational Operator', 'ChargePathOK', ...
    [1120 390 1160 430], 'Operator', '>=');
addb(s, 'simulink/Math Operations/Product', 'GateCharge', [1210 180 1250 220]);
addb(s, 'simulink/Math Operations/Gain', 'BuckEff', [1300 180 1370 220], ...
    'Gain', 'P.eta_buck');

% Energy, in kWh, logged rather than discarded.
addb(s, 'simulink/Math Operations/Gain', 'ToKW', [1070 95 1130 135], 'Gain', '1/1000');
addb(s, 'simulink/Continuous/Integrator', 'EnergyInt', [1190 95 1230 135], ...
    'InitialCondition', '0');
addb(s, 'simulink/Math Operations/Gain', 'ToKWh', [1280 95 1340 135], 'Gain', '1/3600');

addb(s, 'simulink/Sinks/Out1', 'BusVolts',  [1430 303 1460 317], 'Port', '1');
addb(s, 'simulink/Sinks/Out1', 'CurrentA',  [1430 103 1460 117], 'Port', '2');
addb(s, 'simulink/Sinks/Out1', 'ChargeW',   [1430 193 1460 207], 'Port', '3');
addb(s, 'simulink/Sinks/Out1', 'DCWatts',   [1430 143 1460 157], 'Port', '4');
addb(s, 'simulink/Sinks/Out1', 'EnergyKWh', [1430  53 1460  67], 'Port', '5');

wire(s, 'ShaftW/1',       'Alternator/1');
wire(s, 'Q_lpm/1',        'OpenCircuitAC/1');
wire(s, 'OpenCircuitAC/1','BridgeRatio/1');
wire(s, 'BridgeRatio/1',  'DiodeDrop/1');
wire(s, 'DiodeDrop/1',    'BusFloor/1');
wire(s, 'BusFloor/1',     'BusVolts/1');
wire(s, 'BridgeRatio/1',  'Conducting/1');
wire(s, 'CutIn/1',        'Conducting/2');
wire(s, 'BridgeRatio/1',  'GuardV/1');
wire(s, 'VFloor/1',       'GuardV/2');
wire(s, 'Alternator/1',   'RawCurrent/1');
wire(s, 'GuardV/1',       'RawCurrent/2');
wire(s, 'RawCurrent/1',   'GateCurrent/1');
wire(s, 'Conducting/1',   'GateCurrent/2');
wire(s, 'GateCurrent/1',  'CurrentA/1');
wire(s, 'GateCurrent/1',  'RectLoss/1');
wire(s, 'Alternator/1',   'DCPower/1');
wire(s, 'RectLoss/1',     'DCPower/2');
wire(s, 'DCPower/1',      'DCFloor/1');
wire(s, 'DCFloor/1',      'DCWatts/1');
wire(s, 'DCFloor/1',      'ToKW/1');
wire(s, 'ToKW/1',         'EnergyInt/1');
wire(s, 'EnergyInt/1',    'ToKWh/1');
wire(s, 'ToKWh/1',        'EnergyKWh/1');
wire(s, 'BusFloor/1',     'ChargePathOK/1');
wire(s, 'BuckVinReq/1',   'ChargePathOK/2');
wire(s, 'DCFloor/1',      'GateCharge/1');
wire(s, 'ChargePathOK/1', 'GateCharge/2');
wire(s, 'GateCharge/1',   'BuckEff/1');
wire(s, 'BuckEff/1',      'ChargeW/1');
end


%% ========================================================================
%  5. BATTERY AND LOAD
%  ========================================================================
function buildBatteryLoad(model)
s = [model '/Battery And Load'];
openSubsystem(s, 'ChargeW');
addb(s, 'simulink/Sources/In1', 'Q_lpm',    [40 240 70 254], 'Port', '2');
addb(s, 'simulink/Sources/In1', 'RainIntensity', [40 360 70 374], 'Port', '3');

% --- LED trigger: flow above threshold OR rain detected, held 15 s -------
addb(s, 'simulink/Sources/Constant', 'FlowThresh', [130 290 220 330], ...
    'Value', 'P.flow_trigger_lpm');
addb(s, 'simulink/Logic and Bit Operations/Relational Operator', 'FlowHigh', ...
    [270 240 310 280], 'Operator', '>=');
addb(s, 'simulink/Sources/Constant', 'RainThresh', [130 410 220 450], ...
    'Value', 'P.rain_thresh_mmh');
addb(s, 'simulink/Logic and Bit Operations/Relational Operator', 'RainWet', ...
    [270 360 310 400], 'Operator', '>=');
addb(s, 'simulink/Logic and Bit Operations/Logical Operator', 'TriggerOR', ...
    [370 300 410 340], 'Operator', 'OR', 'Inputs', '2');

% Latch the time of the last trigger and hold. Memory breaks the algebraic
% loop; this pattern is carried over unchanged from Appendix D, where it
% was correct.
addb(s, 'simulink/Sources/Clock', 'SimClock', [370 450 410 490]);
addb(s, 'simulink/Signal Routing/Switch', 'LatchOnTime', [480 440 520 500], ...
    'Criteria', 'u2 > Threshold', 'Threshold', '0.5');
addb(s, 'simulink/Discrete/Memory', 'HoldMemory', [480 550 540 590], ...
    'InitialCondition', '-1e6');
addb(s, 'simulink/Math Operations/Sum', 'Elapsed', [600 440 630 470], 'Inputs', '+-');
addb(s, 'simulink/Sources/Constant', 'HoldTime', [600 530 670 570], ...
    'Value', 'P.light_hold_s');
addb(s, 'simulink/Logic and Bit Operations/Relational Operator', 'WithinHold', ...
    [720 440 760 480], 'Operator', '<=');

% --- Load budget ---------------------------------------------------------
% LED draw from the WS2812B datasheet and the firmware brightness, plus the
% rest of the monitoring system. Appendix D counted only the LEDs, and then
% never connected even those to the battery.
addb(s, 'simulink/Math Operations/Gain', 'LedWatts', [820 440 940 480], ...
    'Gain', ['P.n_led * (P.led_ma_quiescent + P.led_brightness * ' ...
             '(P.led_ma_full - P.led_ma_quiescent)) / 1000 * P.led_volts']);
addb(s, 'simulink/Sources/Constant', 'BaseLoad', [820 560 940 600], ...
    'Value', 'P.pi_watts + P.arduino_watts + P.sensor_watts');
addb(s, 'simulink/Math Operations/Sum', 'TotalLoad', [1000 480 1030 510], ...
    'Inputs', '++');

% --- Net power into the pack, integrated as state of charge -------------
addb(s, 'simulink/Math Operations/Sum', 'NetWatts', [1100 100 1130 130], ...
    'Inputs', '+-');
addb(s, 'simulink/Math Operations/Gain', 'WattsToSOC', [1180 95 1280 135], ...
    'Gain', '1 / (P.batt_capacity_wh * 3600)');

% Saturation INSIDE the integrator, so the state itself stops at the rails.
% Clipping after an integrator leaves the state winding past the limit and
% the output then lags reality by however long it takes to climb back.
addb(s, 'simulink/Continuous/Integrator', 'SOCInt', [1330 95 1370 135], ...
    'InitialCondition', 'P.soc_initial', ...
    'LimitOutput', 'on', 'UpperSaturationLimit', '1', 'LowerSaturationLimit', '0');

addb(s, 'simulink/Math Operations/Gain', 'SOCPercent', [1430 95 1500 135], 'Gain', '100');
addb(s, 'simulink/Math Operations/Gain', 'SOCToSpan', [1430 200 1520 240], ...
    'Gain', 'P.batt_v_full - P.batt_v_empty');
addb(s, 'simulink/Math Operations/Bias', 'AddVEmpty', [1570 200 1630 240], ...
    'Bias', 'P.batt_v_empty');

addb(s, 'simulink/Sinks/Out1', 'SOCPct',    [1570 108 1600 122], 'Port', '1');
addb(s, 'simulink/Sinks/Out1', 'LedOn',     [1570 453 1600 467], 'Port', '2');
addb(s, 'simulink/Sinks/Out1', 'BattVolts', [1690 213 1720 227], 'Port', '3');
addb(s, 'simulink/Sinks/Out1', 'NetW',      [1570 303 1600 317], 'Port', '4');

wire(s, 'Q_lpm/1',         'FlowHigh/1');
wire(s, 'FlowThresh/1',    'FlowHigh/2');
wire(s, 'RainIntensity/1', 'RainWet/1');
wire(s, 'RainThresh/1',    'RainWet/2');
wire(s, 'FlowHigh/1',      'TriggerOR/1');
wire(s, 'RainWet/1',       'TriggerOR/2');
wire(s, 'SimClock/1',      'LatchOnTime/1');
wire(s, 'TriggerOR/1',     'LatchOnTime/2');
wire(s, 'HoldMemory/1',    'LatchOnTime/3');
wire(s, 'LatchOnTime/1',   'HoldMemory/1');
wire(s, 'SimClock/1',      'Elapsed/1');
wire(s, 'LatchOnTime/1',   'Elapsed/2');
wire(s, 'Elapsed/1',       'WithinHold/1');
wire(s, 'HoldTime/1',      'WithinHold/2');
wire(s, 'WithinHold/1',    'LedOn/1');
wire(s, 'WithinHold/1',    'LedWatts/1');
wire(s, 'LedWatts/1',      'TotalLoad/1');
wire(s, 'BaseLoad/1',      'TotalLoad/2');
wire(s, 'ChargeW/1',       'NetWatts/1');
wire(s, 'TotalLoad/1',     'NetWatts/2');
wire(s, 'NetWatts/1',      'NetW/1');
wire(s, 'NetWatts/1',      'WattsToSOC/1');
wire(s, 'WattsToSOC/1',    'SOCInt/1');
wire(s, 'SOCInt/1',        'SOCPercent/1');
wire(s, 'SOCPercent/1',    'SOCPct/1');
wire(s, 'SOCInt/1',        'SOCToSpan/1');
wire(s, 'SOCToSpan/1',     'AddVEmpty/1');
wire(s, 'AddVEmpty/1',     'BattVolts/1');
end


%% ========================================================================
%  6. SENSOR EMULATION - predict the READING, not just the quantity
%  ========================================================================
function buildSensors(model)
s = [model '/Sensor Emulation'];
openSubsystem(s, 'TrueCurrent');
addb(s, 'simulink/Sources/In1', 'BusVolts', [40 240 70 254], 'Port', '2');

% The point of this stage: a model that predicts only the true current
% cannot explain why the prototype reported 0.23 A. One that also models
% the MAX471, the 10-bit ADC and the firmware deadband predicts the READING,
% and the reading it predicts is 0.000 A.
addb(s, 'simulink/Math Operations/Gain', 'ToCounts', [150 90 260 130], ...
    'Gain', '1 / P.current_lsb_a');
addb(s, 'simulink/Math Operations/Rounding Function', 'Quantise', [300 90 380 130], ...
    'Operator', 'floor');
addb(s, 'simulink/Math Operations/Gain', 'BackToAmps', [420 90 530 130], ...
    'Gain', 'P.current_lsb_a');

addb(s, 'simulink/Sources/Constant', 'Deadband', [420 200 530 240], ...
    'Value', 'P.current_deadband_a');
addb(s, 'simulink/Logic and Bit Operations/Relational Operator', 'AboveDeadband', ...
    [580 190 620 230], 'Operator', '>=');
addb(s, 'simulink/Math Operations/Product', 'ApplyDeadband', [680 90 720 130]);

addb(s, 'simulink/Math Operations/Product', 'ReportedWatts', [790 190 830 230]);

% YF-S201 pulse frequency, as the firmware would count it.
addb(s, 'simulink/Sinks/Out1', 'ReportedA', [900 103 930 117], 'Port', '1');
addb(s, 'simulink/Sinks/Out1', 'ReportedW', [900 203 930 217], 'Port', '2');
addb(s, 'simulink/Sinks/Out1', 'CountsRaw', [900 303 930 317], 'Port', '3');

wire(s, 'TrueCurrent/1',   'ToCounts/1');
wire(s, 'ToCounts/1',      'Quantise/1');
wire(s, 'ToCounts/1',      'CountsRaw/1');
wire(s, 'Quantise/1',      'BackToAmps/1');
wire(s, 'BackToAmps/1',    'AboveDeadband/1');
wire(s, 'Deadband/1',      'AboveDeadband/2');
wire(s, 'BackToAmps/1',    'ApplyDeadband/1');
wire(s, 'AboveDeadband/1', 'ApplyDeadband/2');
wire(s, 'ApplyDeadband/1', 'ReportedA/1');
wire(s, 'ApplyDeadband/1', 'ReportedWatts/1');
wire(s, 'BusVolts/1',      'ReportedWatts/2');
wire(s, 'ReportedWatts/1', 'ReportedW/1');
end


%% ========================================================================
%  7. LIVE COMPARISON  -  measured against predicted, as it runs
%  ========================================================================
function buildLiveComparison(model)
s = [model '/Live Comparison'];
openSubsystem(s, 'PredictedW');
addb(s, 'simulink/Sources/In1', 'T1Measured', [40 220 70 234], 'Port', '2');
addb(s, 'simulink/Sources/In1', 'T2Measured', [40 300 70 314], 'Port', '3');

% The cascade shares the head, so each runner's share of the predicted
% output is its share of the head.
addb(s, 'simulink/Math Operations/Gain', 'T1Share', [150 80 250 120], ...
    'Gain', 'P.head_split(1)');
addb(s, 'simulink/Math Operations/Gain', 'T2Share', [150 150 250 190], ...
    'Gain', 'P.head_split(min(2,numel(P.head_split)))');

addb(s, 'simulink/Math Operations/Sum', 'MeasuredTotal', [150 250 180 280], ...
    'Inputs', '++');
addb(s, 'simulink/Math Operations/Sum', 'Error', [330 250 360 280], 'Inputs', '+-');
addb(s, 'simulink/Math Operations/Abs', 'AbsError', [420 245 460 285]);

% Relative, not absolute: a watt figure means nothing across the range of
% flows this unit sees. Guarded so a zero measurement cannot divide.
addb(s, 'simulink/Math Operations/Abs', 'AbsMeasured', [250 340 290 380]);
addb(s, 'simulink/Sources/Constant', 'TinyFloor', [250 420 320 460], 'Value', '1e-9');
addb(s, 'simulink/Math Operations/MinMax', 'GuardDiv', [360 350 400 390], ...
    'Function', 'max', 'Inputs', '2');
addb(s, 'simulink/Math Operations/Divide', 'RelError', [460 340 500 380], ...
    'Inputs', '*/');
addb(s, 'simulink/Math Operations/Gain', 'ToPercent', [540 340 600 380], 'Gain', '100');

addb(s, 'simulink/Sources/Constant', 'AlarmLevel', [540 430 640 470], ...
    'Value', 'P.live_alarm_pct');
addb(s, 'simulink/Logic and Bit Operations/Relational Operator', 'Alarm', ...
    [680 350 720 390], 'Operator', '>');

% One scope with both traces. This is the picture the demo needs: the
% prototype and its twin on the same axes, diverging or not.
addb(s, 'simulink/Signal Routing/Mux', 'CompareMux', [600 90 605 200], 'Inputs', '3');
addb(s, 'simulink/Sinks/Scope', 'MeasuredVsPredicted', [680 110 720 150], ...
    'NumInputPorts', '1');

addb(s, 'simulink/Sinks/Out1', 'ErrorW',   [800 258 830 272], 'Port', '1');
addb(s, 'simulink/Sinks/Out1', 'PctError', [800 353 830 367], 'Port', '2');
addb(s, 'simulink/Sinks/Out1', 'AlarmFlag',[800 363 830 377], 'Port', '3');

wire(s, 'PredictedW/1',  'T1Share/1');
wire(s, 'PredictedW/1',  'T2Share/1');
wire(s, 'T1Measured/1',  'MeasuredTotal/1');
wire(s, 'T2Measured/1',  'MeasuredTotal/2');

wire(s, 'PredictedW/1',  'Error/1');
wire(s, 'MeasuredTotal/1', 'Error/2');
wire(s, 'Error/1',       'AbsError/1');
wire(s, 'Error/1',       'ErrorW/1');

wire(s, 'MeasuredTotal/1', 'AbsMeasured/1');
wire(s, 'AbsMeasured/1', 'GuardDiv/1');
wire(s, 'TinyFloor/1',   'GuardDiv/2');
wire(s, 'AbsError/1',    'RelError/1');
wire(s, 'GuardDiv/1',    'RelError/2');
wire(s, 'RelError/1',    'ToPercent/1');
wire(s, 'ToPercent/1',   'PctError/1');

wire(s, 'ToPercent/1',   'Alarm/1');
wire(s, 'AlarmLevel/1',  'Alarm/2');
wire(s, 'Alarm/1',       'AlarmFlag/1');

wire(s, 'T1Share/1',       'CompareMux/1');
wire(s, 'T2Share/1',       'CompareMux/2');
wire(s, 'MeasuredTotal/1', 'CompareMux/3');
wire(s, 'CompareMux/1',    'MeasuredVsPredicted/1');
end


%% ========================================================================
%  Helpers
%  ========================================================================
function openSubsystem(s, firstInputName)
%OPENSUBSYSTEM  Strip the default In1->Out1 pair a new Subsystem comes with.
delete_line(s, 'In1/1', 'Out1/1');
delete_block([s '/Out1']);
set_param([s '/In1'], 'Name', firstInputName, 'Position', [40 100 70 114]);
end

function addb(parent, src, name, pos, varargin)
dst = [parent '/' name];
add_block(src, dst, 'Position', pos);
for k = 1:2:numel(varargin)
    try
        set_param(dst, varargin{k}, varargin{k+1});
    catch err
        error('watapac:paramFailed', ...
            ['Could not set %s on %s.\n  value: %s\n  %s\n' ...
             'Block parameter names move between releases; this one needs checking.'], ...
            varargin{k}, name, toChar(varargin{k+1}), err.message);
    end
end
end

function wire(parent, src, dst)
try
    add_line(parent, src, dst, 'autorouting', 'on');
catch err
    error('watapac:wireFailed', 'Could not connect %s -> %s in %s\n  %s', ...
        src, dst, parent, err.message);
end
end

function opts = parseOptions(args)
opts = struct('Params', [], 'ModelName', 'watapac_twin', 'Open', true, 'Save', true);
if mod(numel(args), 2) ~= 0
    error('watapac:badArgs', 'Options must be name-value pairs.');
end
for i = 1:2:numel(args)
    name = char(args{i});
    if ~isfield(opts, name)
        error('watapac:badArgs', 'Unknown option "%s". Valid: %s.', ...
            name, strjoin(fieldnames(opts)', ', '));
    end
    opts.(name) = args{i+1};
end
if isempty(opts.Params); opts.Params = watapac_twin_params(); end
end

function s = toChar(v)
if ischar(v); s = v; elseif isnumeric(v) || islogical(v); s = mat2str(v);
else; s = ['<' class(v) '>']; end
end

function closeIfIncomplete(model)
try
    if bdIsLoaded(model)
        close_system(model, 0);
        fprintf(2, '  build failed - discarded the partial model.\n');
    end
catch
end
end
