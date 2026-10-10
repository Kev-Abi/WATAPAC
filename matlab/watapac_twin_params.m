function P = watapac_twin_params(varargin)
%WATAPAC_TWIN_PARAMS  Every constant the WATAPAC digital twin uses.
%
%   One file, so the Simulink model, the plant function and the validation
%   script can never disagree about a number. Each value carries its source:
%
%     [MS]   measured or stated in the manuscript (table or section named)
%     [FW]   firmware constant, Appendix B (watapac_sensors.ino)
%     [BOM]  component, Appendix A materials list
%     [DS]   component datasheet
%     [CAL]  calibrated so the model reproduces a measured value
%     [EST]  engineering estimate -- NOT measured, and the first thing to
%            question when the model disagrees with reality
%
%   Override any field:  P = watapac_twin_params('eta_turbine', 0.15)

%% ---- Physical constants ------------------------------------------------
P.rho            = 1000;      % kg/m^3   water density
P.g              = 9.81;      % m/s^2

%% ---- Test condition ----------------------------------------------------
P.rain_yellow_mmh = 15;       % [MS] PAGASA Yellow, Methodology
P.trial_seconds   = 16*60+40; % [MS] 16 min 40 s per trial
P.n_trials        = 5;        % [MS]

%% ---- Scale -------------------------------------------------------------
P.lambda          = 1/3.6;    % [MS] model : full scale
P.inlet_full_mm   = [1510 1210 2120];        % [MS] DPWH standard inlet
P.inlet_model_mm  = [419.4 336.1 588.9];     % [MS] scaled prototype

%% ---- Stage 1: rainfall -> runoff (rational method) ---------------------
% Q = C * i * A / 3.6e6, with i in mm/h and A in m^2.
P.C_runoff        = 0.95;     % [EST] bare steel/acrylic test table, near-impervious

% The test table is 0.925 x 0.745 m = 0.689 m^2, but the pressure washer
% wets a wider area than the table itself, so the effective catchment is
% back-calculated from the measured flow rather than assumed.
%   A = Q_measured * 3.6e6 / (C * i)
%     = 4.733e-6 * 3.6e6 / (0.95 * 15) = 1.196 m^2
P.A_catch_eff     = 1.196;    % [CAL] m^2, reproduces the 0.284 L/min mean

% Kept separate, for extrapolating to a real street inlet. NOT used in the
% trial simulation -- mixing the two is what makes a scaled twin wrong.
P.A_catch_full    = 1200;     % [EST] m^2, contributing area of a real inlet

%% ---- Stage 2: two-stage filtration -------------------------------------
P.debris_total_g   = 25.0;    % [MS] fixed load per trial
P.debris_leaves_g  = 14.5;    % [MS] 58 %, after Tanchuling & Osorio (2020)
P.debris_plastic_g = 10.5;    % [MS] 42 %

% Per-type capture, set so the weighted mean reproduces the measured 97.4 %:
%   (14.5*0.990 + 10.5*0.951) / 25 = 0.9736
% Leaves are large and flat and the inclined mesh catches nearly all of them;
% plastic fragments are the smaller and more variable share.
P.capture_leaves   = 0.990;   % [CAL]
P.capture_plastic  = 0.951;   % [CAL]

% Flow blockage caused by retained debris, as a fraction per gram.
%
% This is an UPPER BOUND, not a fit. The experiment found no significant
% flow difference against the conventional model (t(8) = -0.339, p = .743)
% with ~24.3 g retained, and WATAPAC actually passed 3.6 % MORE water. So
% whatever blockage the mesh causes over one 1000 s trial is too small to
% detect; this value keeps it under 2 % at the full load.
P.blockage_per_g   = 0.0008;  % [CAL] upper bound from the null result
P.blockage_max     = 0.60;    % [EST] ceiling for long-duration extrapolation

%% ---- Stage 3: cascade turbines -----------------------------------------
P.n_turbine       = 2;        % [MS] Turbine 1 then Turbine 2

% Head at each stage. The manuscript places T1 at the point of maximum drop
% below the mesh and T2 below a slope beneath T1. Measured outputs differed
% by 1.4 % (1.366 W vs 1.385 W), which is consistent with an even split.
P.head_total_m    = 0.45;     % [EST] as used in Appendix D
P.head_split      = [0.5 0.5];% [CAL] consistent with the 1.4 % output gap

% Crossflow (Banki-Michell) runner, Methodology > Turbine Runner Design
P.runner_d_outer_m = 0.090;   % [MS]
P.runner_d_inner_m = 0.051;   % [MS] -> ratio 0.57
P.runner_length_m  = 0.360;   % [MS]
P.runner_blades    = 15;      % [MS]

% Hydraulic to mechanical efficiency.
%
% OPTIMISTIC. Published crossflow efficiencies of 0.6-0.8 come from machines
% running at design flow and Reynolds numbers orders of magnitude above this
% one. At 0.28 L/min spread over a 360 mm wide runner the flow is a trickle
% and viscous losses dominate. 0.35 is carried over from Appendix D; treat
% anything above ~0.20 at this scale as unverified.
P.eta_turbine     = 0.35;     % [EST]
P.eta_generator   = 0.70;     % [EST] 3-phase micro alternator; also optimistic
                              %       at low rpm, where cogging and iron
                              %       losses are a large share of the output

% Open-circuit AC volts per L/min, per turbine, before rectification.
% Back-calculated from the measured 5.94 V DC plus the rectifier drop:
%   V_ac = (5.94 + 1.4) / 1.35 = 5.44 V at 0.284 L/min -> 19.1 V per L/min
P.kv_ac_per_lpm   = 19.1;     % [CAL] against Table 5; see the energy audit

%% ---- Stage 4: rectifier and charge controller --------------------------
% 3-phase diode bridge: current passes through two diodes in series at any
% instant, so the drop is 2 * Vf. This costs 1.4 V of a ~6 V output -- a
% quarter of it -- and Appendix D omits it entirely.
P.rect_vf_per_diode = 0.70;   % [DS] silicon
P.rect_diodes_in_path = 2;    % [DS] 3-phase bridge
P.rect_v_drop     = P.rect_vf_per_diode * P.rect_diodes_in_path;
P.rect_ac_to_dc   = 1.35;     % [DS] Vdc / Vac(rms, line-line), 3-phase bridge

% XL4015 adjustable buck converter used as the charge controller. [BOM]
% A BUCK ONLY STEPS DOWN. These two numbers decide whether the battery can
% be charged at all; see watapac_plant.
P.buck_vin_min    = 8.0;      % [DS] XL4015 minimum input
P.buck_dropout_v  = 1.5;      % [DS] headroom needed above the output voltage
P.eta_buck        = 0.87;     % [DS] typical at light load

%% ---- Stage 5: battery --------------------------------------------------
% [BOM] lists an 11.1 V 5000 mAh LiPo -- a 3-cell pack.
%
% Three different battery models exist across the project and none matches
% this one. See watapac_validate, which prints the comparison:
%   Appendix B firmware : empty 11.8 V, full 12.7 V  (3.93-4.23 V/cell)
%   Appendix C server   : empty  9.9 V, full 11.1 V  (3.30-3.70 V/cell)
%   Appendix D twin     : empty 11.8 V, full 12.7 V, 7.0 Ah
P.batt_cells      = 3;        % [BOM]
P.batt_v_cell_empty = 3.00;   % [DS] LiPo discharge floor
P.batt_v_cell_full  = 4.20;   % [DS] LiPo charge ceiling
P.batt_v_empty    = P.batt_cells * P.batt_v_cell_empty;   % 9.0 V
P.batt_v_full     = P.batt_cells * P.batt_v_cell_full;    % 12.6 V
P.batt_v_nominal  = 11.1;     % [BOM]
P.batt_capacity_ah = 5.0;     % [BOM]
P.batt_capacity_wh = P.batt_capacity_ah * P.batt_v_nominal;   % 55.5 Wh
P.soc_initial     = 0.50;     % [EST]

%% ---- Stage 6: electrical load ------------------------------------------
% WS2812B at the firmware's brightness setting. Full white is ~60 mA per LED
% at 5 V; brightness scales the duty cycle, and each chip draws ~1 mA even
% when dark.
P.n_led           = 125;      % [FW] LED_COUNT
P.led_brightness  = 75/255;   % [FW] LED_BRIGHTNESS
P.led_ma_full     = 60;       % [DS] per LED, full white
P.led_ma_quiescent = 1.0;     % [DS] per LED, driver idle
P.led_volts       = 5.0;      % [DS]

% The rest of the monitoring system, which Appendix D leaves out of the
% energy balance entirely. The Recommendation section already identifies
% the Pi as the problem; these numbers say how big a problem.
P.pi_watts        = 4.0;      % [DS] Raspberry Pi 4B, idle with WiFi
P.arduino_watts   = 0.25;     % [DS] Uno, ~50 mA at 5 V
P.sensor_watts    = 0.10;     % [EST] flow, rain, 2x MAX471, 2x voltage

%% ---- Firmware thresholds (mirrored so the twin behaves like the unit) --
P.flow_trigger_lpm = 1.0;     % [FW] FLOW_TRIGGER_LPM
P.light_hold_s     = 15.0;    % [FW] LIGHT_ON_MS
P.pulses_per_litre = 450;     % [FW] YF-S201
P.rain_thresh_mmh  = 0.5;     % [EST] intensity counted as "wet"
P.current_deadband_a = 0.025; % [FW] readings below this report as zero

%% ---- Sensor hardware limits (why the measurements are what they are) ---
P.adc_bits        = 10;       % [DS] ATmega328P
P.adc_vref        = 5.0;      % [DS]
P.max471_mv_per_a = 1000;     % [FW] MAX471_MV_PER_AMP
P.max471_range_a  = 3.0;      % [DS] full scale
P.adc_lsb_v       = P.adc_vref / (2^P.adc_bits - 1);
P.current_lsb_a   = P.adc_lsb_v / (P.max471_mv_per_a / 1000);

%% ---- Live monitoring ---------------------------------------------------
% How far measurement may drift from prediction before the twin raises an
% alarm. Relative, not absolute: a watt figure means nothing across the
% range of flows this unit sees.
%
% Set well above the current 134x disagreement, which is a calibration
% fault rather than a fault in the drain. Bring it down to something like
% 25 % once the current sensor is fixed, and it will then catch the things
% it is meant to: a blocked mesh, a stalled runner, a dead turbine.
P.live_alarm_pct   = 50;      % [EST]
P.live_period_s    = 1.0;     % matches the Arduino's 1 Hz report
P.live_timeout_s   = 0.8;     % HTTP read timeout, under the poll period

%% ---- Reference load ----------------------------------------------------
P.powerbank_kwh   = 0.074;    % [MS] 20,000 mAh at 3.7 V
P.powerbank_max_kw = 0.018;   % [MS] manufacturer maximum input

P = applyOverrides(P, varargin);
end


function P = applyOverrides(P, args)
if mod(numel(args), 2) ~= 0
    error('watapac_twin_params:badArgs', 'Overrides must be name-value pairs.');
end
for i = 1:2:numel(args)
    name = char(args{i});
    if ~isfield(P, name)
        error('watapac_twin_params:noSuchField', 'No parameter named "%s".', name);
    end
    P.(name) = args{i+1};
end

% Re-derive anything that depends on an overridable field.
P.rect_v_drop      = P.rect_vf_per_diode * P.rect_diodes_in_path;
P.batt_v_empty     = P.batt_cells * P.batt_v_cell_empty;
P.batt_v_full      = P.batt_cells * P.batt_v_cell_full;
P.batt_capacity_wh = P.batt_capacity_ah * P.batt_v_nominal;
P.adc_lsb_v        = P.adc_vref / (2^P.adc_bits - 1);
P.current_lsb_a    = P.adc_lsb_v / (P.max471_mv_per_a / 1000);

assert(abs(sum(P.head_split) - 1) < 1e-9, ...
    'watapac_twin_params: head_split must sum to 1.');
assert(numel(P.head_split) == P.n_turbine, ...
    'watapac_twin_params: head_split needs one entry per turbine.');
assert(abs((P.debris_leaves_g + P.debris_plastic_g) - P.debris_total_g) < 1e-9, ...
    'watapac_twin_params: leaves + plastic must equal debris_total_g.');
end
