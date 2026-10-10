function R = watapac_validate(P)
%WATAPAC_VALIDATE  Compare the digital twin against the measured trials.
%
%   This is the part that makes it a digital twin rather than a simulation:
%   it runs the model over the same five trials the prototype was tested on
%   and prints model against measurement, side by side.
%
%   Where the two agree, the model is evidence that the mechanism is
%   understood. Where they disagree, the disagreement is the finding --
%   so nothing here is tuned to hide a gap.
%
%   R = WATAPAC_VALIDATE returns every comparison as a struct.

if nargin < 1 || isempty(P); P = watapac_twin_params(); end
D = watapac_trial_data();

line('=');
fprintf(' WATAPAC DIGITAL TWIN - VALIDATION AGAINST MEASURED TRIALS\n');
fprintf(' %d trials, %d s each, %g mm/h, %g g debris\n', ...
    P.n_trials, D.trial_seconds, P.rain_yellow_mmh, D.debris_load_g);
line('=');

%% ---- 0. Do the published tables match their own raw data? -------------
section('0. PUBLISHED TABLES vs APPENDIX G RAW DATA');
fprintf('  Recomputed from the raw volumes, masses, currents and voltages.\n');
fprintf('  A mismatch here would be an arithmetic error in the paper.\n\n');
checks = {
  'conventional flow (L/min)',  mean(D.conv.flow_lpm),       D.published.conv_flow_mean,      1e-3
  'conventional filtration (%)',mean(D.conv.filtration_pct), D.published.conv_filtration_mean,0.05
  'WATAPAC flow (L/min)',       mean(D.wat.flow_lpm),        D.published.wat_flow_mean,       1e-3
  'WATAPAC filtration (%)',     mean(D.wat.filtration_pct),  D.published.wat_filtration_mean, 0.05
  'T1 power (kW)',              mean(D.t1.power_w)/1000,     D.published.t1_power_kw_mean,    5e-6
  'T2 power (kW)',              mean(D.t2.power_w)/1000,     D.published.t2_power_kw_mean,    5e-6
  'combined power (kW)',        mean(D.combined.power_w)/1000,D.published.combined_power_kw,  5e-6
  'combined energy (kWh)',      mean(D.combined.energy_wh)/1000,D.published.combined_energy_kwh,5e-6
  'charging time (h)',          mean(D.combined.charge_hours),D.published.charge_hours_mean,  0.02
};
fprintf('  %-30s %12s %12s   %s\n', 'quantity', 'recomputed', 'published', '');
R.table_check_ok = true;
for i = 1:size(checks,1)
    ok = abs(checks{i,2} - checks{i,3}) <= checks{i,4};
    R.table_check_ok = R.table_check_ok && ok;
    fprintf('  %-30s %12.6g %12.6g   %s\n', checks{i,1}, checks{i,2}, checks{i,3}, mark(ok));
end
fprintf('\n  %s\n', ternary(R.table_check_ok, ...
    'Every published figure reproduces from the raw data.', ...
    'SOME PUBLISHED FIGURES DO NOT REPRODUCE - see the rows marked FAIL.'));

%% ---- 1. Hydraulic stages: does the model match? -----------------------
section('1. FLOW AND FILTRATION - model vs measured');
S = watapac_plant(P.rain_yellow_mmh, D.debris_load_g, P);
R.model = S;

cmp('water flow rate (L/min)', S.Q_lpm, D.wat.flow_lpm);
cmp('filtration efficiency (%)', S.filtration_pct, D.wat.filtration_pct);
fprintf('\n  Both stages are calibrated to these means (A_catch_eff and the\n');
fprintf('  per-type capture rates), so agreement is expected. What matters is\n');
fprintf('  that one consistent catchment area and one capture model reproduce\n');
fprintf('  both measurements at once.\n');

fprintf('\n  Flow blockage from retained debris: %.2f %%\n', 100*S.blockage_frac);
fprintf('  Measured difference against the conventional model was not\n');
fprintf('  significant (t(8) = -0.339, p = .743), and WATAPAC passed %.1f %% MORE\n', ...
    100*(mean(D.wat.flow_lpm)/mean(D.conv.flow_lpm) - 1));
fprintf('  water, so this is an upper bound rather than a fitted value.\n');

%% ---- 2. THE ENERGY AUDIT ----------------------------------------------
section('2. ENERGY BALANCE - where the model and the measurement part company');
Q = D.wat.flow_lpm / 60000;
hyd_w = P.rho * P.g * Q * P.head_total_m;
meas_w = D.combined.power_w;

fprintf('  %-7s %12s %14s %14s %10s\n', 'trial', 'flow(L/min)', 'hydraulic(mW)', 'measured(mW)', 'ratio');
for k = 1:P.n_trials
    fprintf('  %-7d %12.3f %14.2f %14.1f %9.0fx\n', ...
        k, D.wat.flow_lpm(k), hyd_w(k)*1000, meas_w(k)*1000, meas_w(k)/hyd_w(k));
end
R.energy_ratio = mean(meas_w ./ hyd_w);
fprintf('\n  Mean implied efficiency: %.0f %%.  The physical maximum is 100 %%.\n', 100*R.energy_ratio);

fprintf('\n  For %.2f W to be real at %.3f L/min, one of these must hold:\n', mean(meas_w), mean(D.wat.flow_lpm));
fprintf('    head of %.1f m        (the prototype is %.3f m tall)\n', ...
    mean(meas_w)/(P.rho*P.g*mean(Q)), P.inlet_model_mm(3)/1000);
fprintf('    flow of %.1f L/min    (measured %.3f L/min)\n', ...
    mean(meas_w)/(P.rho*P.g*P.head_total_m*P.eta_turbine*P.eta_generator)*60000, mean(D.wat.flow_lpm));

ratios = meas_w ./ hyd_w;
R.energy_ratio_cv = 100 * stddev(ratios) / mean(ratios);
fprintf('\n  The ratio is %0.0f-%0.0fx in EVERY trial across a %.0f %% spread in flow,\n', ...
    min(ratios), max(ratios), ...
    100*(max(D.wat.flow_lpm)-min(D.wat.flow_lpm))/mean(D.wat.flow_lpm));
fprintf('  varying by only %.1f %% itself.\n', R.energy_ratio_cv);
fprintf('\n  That constancy is the whole argument. A real turbine has an\n');
fprintf('  efficiency curve -- it peaks near design flow and falls away on\n');
fprintf('  either side -- so its output-to-input ratio cannot stay flat to\n');
fprintf('  %.1f %% while the flow moves %.0f %%. A fixed multiplier between the\n', ...
    R.energy_ratio_cv, 100*(max(D.wat.flow_lpm)-min(D.wat.flow_lpm))/mean(D.wat.flow_lpm));
fprintf('  true output and the recorded one does exactly that. This is a\n');
fprintf('  calibration scale error, not noise or a loose connection.\n');

%% ---- 3. Can the instrument even see the real current? -----------------
section('3. INSTRUMENT RESOLUTION - why the current reading cannot be right');
fprintf('  Model prediction at %g mm/h:\n', P.rain_yellow_mmh);
fprintf('    hydraulic in      %8.3f mW\n', S.hydraulic_total_w*1000);
fprintf('    shaft (x%.2f)      %8.3f mW\n', P.eta_turbine, S.mech_total_w*1000);
fprintf('    alternator (x%.2f) %8.3f mW\n', P.eta_generator, S.gen_ac_w*1000);
fprintf('    rectifier loss    %8.3f mW   (%.1f V drop x %.3f mA)\n', ...
    S.rect_loss_w*1000, P.rect_v_drop, S.current_a*1000);
fprintf('    DC output         %8.3f mW   at %.2f V\n', S.dc_w*1000, S.v_bus);
fprintf('    -> current        %8.4f mA\n\n', S.current_a*1000);

fprintf('  MAX471 at %g mV/A into a %d-bit ADC: %.2f mA per count\n', ...
    P.max471_mv_per_a, P.adc_bits, P.current_lsb_a*1000);
fprintf('  Predicted current is %.3f of ONE count - below the resolution floor.\n', S.current_in_counts);
fprintf('  Firmware deadband is %.0f mA, so a correct reading reports %.3f A.\n', ...
    P.current_deadband_a*1000, S.current_reported_a);
fprintf('  Reported in Table 5 was %.2f A, which is %.0f counts of something else.\n', ...
    mean(D.t1.current_a), mean(D.t1.current_a)/P.current_lsb_a);
fprintf('\n  The MAX471 is a %g A part being asked to measure a milliamp.\n', P.max471_range_a);

r_i = pearson(D.wat.flow_lpm, D.t1.current_a);
r_v = pearson(D.wat.flow_lpm, D.t1.voltage_v);
fprintf('\n  Against flow:  current r = %.3f,  voltage r = %.3f\n', r_i, r_v);
fprintf('  Both track flow, so the readings are not random - but tracking flow\n');
fprintf('  does not make the magnitude right, and a scale error tracks it too.\n');
R.r_current = r_i; R.r_voltage = r_v;

%% ---- 4. Can the battery be charged at all? ----------------------------
section('4. CHARGE PATH - a finding independent of the energy audit');
fprintf('  Charge controller : XL4015 adjustable buck converter  [Appendix A]\n');
fprintf('  A buck converter steps voltage DOWN. It cannot step up.\n\n');
fprintf('    turbine bus (measured)    %6.2f V   [Tables 5 and 6, in parallel]\n', ...
    mean([D.t1.voltage_v D.t2.voltage_v]));
fprintf('    turbine bus (model)       %6.2f V\n', S.v_bus);
fprintf('    battery, full (3S LiPo)   %6.2f V\n', P.batt_v_full);
fprintf('    XL4015 minimum input      %6.2f V\n', P.buck_vin_min);
fprintf('    needed = max(Vin_min, Vbatt + dropout) = %.2f V\n\n', S.buck_vin_required);
R.charge_path_ok = logical(S.charge_path_ok);
if R.charge_path_ok
    fprintf('    -> charge path VIABLE\n');
else
    fprintf('    -> CHARGE PATH NOT VIABLE. %.2f V in, %.2f V needed.\n', S.v_bus, S.buck_vin_required);
    fprintf('       Even with the energy audit set aside, the circuit as built\n');
    fprintf('       cannot move charge into the pack. Wiring the turbines in\n');
    fprintf('       SERIES gives %.2f V, still short. This needs a BOOST stage.\n', ...
        2*mean([D.t1.voltage_v D.t2.voltage_v]));
end

%% ---- 5. Whole-system energy balance -----------------------------------
section('5. SYSTEM ENERGY BALANCE - generation against the monitoring load');
fprintf('  Generation (model)        %10.4f W\n', S.dc_w);
fprintf('  Generation (as reported)  %10.4f W\n\n', mean(meas_w));
fprintf('  Load:\n');
fprintf('    LED strip  %d x %.1f%% brightness   %7.2f W\n', P.n_led, 100*P.led_brightness, S.led_w_when_on);
fprintf('    Raspberry Pi 4B                %7.2f W\n', P.pi_watts);
fprintf('    Arduino Uno                    %7.2f W\n', P.arduino_watts);
fprintf('    sensors                        %7.2f W\n', P.sensor_watts);
fprintf('    %-30s %7.2f W\n\n', 'TOTAL', S.load_total_w);
R.deficit_ratio_model = S.load_total_w / max(S.dc_w, eps);
R.deficit_ratio_paper = S.load_total_w / mean(meas_w);
fprintf('  Load exceeds generation by %.0fx using the model,\n', R.deficit_ratio_model);
fprintf('  and still by %.0fx using the reported output.\n', R.deficit_ratio_paper);
fprintf('\n  Battery is %.1f Wh. Running the monitoring system flat out drains it\n', P.batt_capacity_wh);
fprintf('  in %.1f h. Refilling it at the modelled %.2f mW takes %.0f days.\n', ...
    P.batt_capacity_wh/S.load_total_w, S.dc_w*1000, P.batt_capacity_wh/S.dc_w/24);
fprintf('\n  The Recommendation section already proposes gating the Pi on the rain\n');
fprintf('  sensor. These numbers size that problem: the Pi alone is %.0fx the\n', P.pi_watts/max(S.dc_w,eps));
fprintf('  modelled generation, so gating it changes the ratio but not the sign.\n');

%% ---- 6. Power bank, both ways -----------------------------------------
section('6. POWER BANK CHARGING TIME');
t_paper = mean(D.combined.charge_hours);
t_model = P.powerbank_kwh * 1000 / S.dc_w;
fprintf('  Using the reported %8.3f mW : %8.2f h   (paper: %.2f h)\n', ...
    mean(meas_w)*1000, t_paper, D.published.charge_hours_mean);
fprintf('  Using the modelled %8.3f mW : %8.0f h  = %.1f years\n', ...
    S.dc_w*1000, t_model, t_model/24/365);
fprintf('  At the power bank maximum %.3f kW  : %6.2f h\n', ...
    P.powerbank_max_kw, P.powerbank_kwh/P.powerbank_max_kw);
R.charge_hours_paper = t_paper;
R.charge_hours_model = t_model;

%% ---- 7. Battery model conflicts ---------------------------------------
section('7. BATTERY MODEL - three definitions across the project');
fprintf('  %-34s %8s %8s %12s\n', 'source', 'empty', 'full', 'per cell');
rows = {
  'Appendix A, materials list',      NaN,  NaN,  '11.1 V 5000 mAh = 3S'
  'Appendix B, firmware',            11.8, 12.7, '3.93 - 4.23 V'
  'Appendix C, Pi server',            9.9, 11.1, '3.30 - 3.70 V'
  'Appendix D, twin script',         11.8, 12.7, '3.93 - 4.23 V, 7.0 Ah'
  'this model (3S LiPo datasheet)',  P.batt_v_empty, P.batt_v_full, '3.00 - 4.20 V'
};
for i = 1:size(rows,1)
    if isnan(rows{i,2})
        fprintf('  %-34s %8s %8s %12s\n', rows{i,1}, '-', '-', rows{i,4});
    else
        fprintf('  %-34s %8.1f %8.1f %12s\n', rows{i,1}, rows{i,2}, rows{i,3}, rows{i,4});
    end
end
fprintf('\n  The firmware range covers only the top ~20%% of a 3S pack, so the\n');
fprintf('  dashboard reads 0%% for most of the usable charge. The Pi server uses\n');
fprintf('  a different and non-overlapping range, so the two disagree about what\n');
fprintf('  the same voltage means. Appendix A says 5.0 Ah; Appendix D says 7.0.\n');

line('=');
fprintf(' SUMMARY\n');
line('-');
fprintf('  Flow and filtration          model reproduces measurement\n');
fprintf('  Energy output                model and measurement differ by %.0fx\n', R.energy_ratio);
fprintf('  Charge path                  %s\n', ternary(R.charge_path_ok, 'viable', 'NOT VIABLE with a buck converter'));
fprintf('  System balance               load exceeds generation %.0fx\n', R.deficit_ratio_model);
line('=');
fprintf('\n');
end


%% ------------------------------------------------------------------------
function cmp(label, model, measured)
fprintf('\n  %s\n', label);
fprintf('    measured   mean %8.4f   sd %7.4f   range %.4f - %.4f\n', ...
    mean(measured), stddev(measured), min(measured), max(measured));
fprintf('    model           %8.4f\n', model);
err = 100 * (model - mean(measured)) / mean(measured);
fprintf('    error      %+7.2f %%  %s\n', err, ...
    ternary(abs(err) < 5, '(within trial-to-trial spread)', '(outside spread)'));
end

function s = stddev(x)
s = sqrt(sum((x - mean(x)).^2) / (numel(x) - 1));
end

function r = pearson(x, y)
x = x(:) - mean(x); y = y(:) - mean(y);
r = (x' * y) / sqrt((x'*x) * (y'*y));
end

function section(t)
fprintf('\n');
line('-');
fprintf(' %s\n', t);
line('-');
end

function line(c)
fprintf('%s\n', repmat(c, 1, 74));
end

function s = mark(ok)
if ok; s = 'ok'; else; s = 'FAIL'; end
end

function s = ternary(c, a, b)
if c; s = a; else; s = b; end
end
