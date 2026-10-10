function S = watapac_plant(rain_mmh, debris_g, P)
%WATAPAC_PLANT  Steady-state physics of the WATAPAC unit, end to end.
%
%   S = WATAPAC_PLANT(rain_mmh, debris_g, P)
%
%   Six stages, following the manuscript's Methodology:
%
%     1  rainfall      -> runoff            rational method
%     2  runoff        -> filtered flow     grate + inclined mesh
%     3  flow          -> shaft power       cascade crossflow turbines
%     4  shaft power   -> DC bus            alternator, rectifier, buck
%     5  DC bus        -> battery           charge path, if it is viable
%     6  loads         -> net balance       LEDs, Pi, Arduino, sensors
%
%   rain_mmh and debris_g may be vectors of the same length (or scalars);
%   every field of S comes back the same size.
%
%   Pure MATLAB -- no Simulink, no toolboxes. That is deliberate: it runs
%   and can be tested anywhere, and watapac_build_twin wires up a Simulink
%   model that mirrors it stage for stage. If the two ever disagree, this
%   file is the reference.
%
%   See also WATAPAC_TWIN_PARAMS, WATAPAC_SIMULATE, WATAPAC_VALIDATE.

if nargin < 3 || isempty(P); P = watapac_twin_params(); end
if nargin < 2 || isempty(debris_g); debris_g = P.debris_total_g; end

[rain_mmh, debris_g] = expandToMatch(rain_mmh, debris_g);
rain_mmh = max(0, rain_mmh);
debris_g = max(0, debris_g);

%% ===== Stage 1: rainfall -> runoff =====================================
% Rational method. i in mm/h, A in m^2, so the 3.6e6 converts mm/h*m^2 to
% m^3/s.
S.rain_mmh  = rain_mmh;
S.Q_cms     = P.C_runoff * rain_mmh * P.A_catch_eff / 3.6e6;
S.Q_lpm     = S.Q_cms * 60000;

%% ===== Stage 2: two-stage filtration ===================================
% Capture is per debris type, because leaves and plastic behave differently
% on an inclined mesh and the manuscript specifies the mix.
leaves_frac  = P.debris_leaves_g  / P.debris_total_g;
plastic_frac = P.debris_plastic_g / P.debris_total_g;

S.debris_in_g       = debris_g;
S.debris_caught_g   = debris_g .* (leaves_frac * P.capture_leaves + ...
                                   plastic_frac * P.capture_plastic);
S.debris_passed_g   = debris_g - S.debris_caught_g;
S.filtration_pct    = 100 * S.debris_caught_g ./ max(debris_g, eps);

% Retained debris partially blocks the mesh. The experiment could not detect
% any blockage at this load, so blockage_per_g is an upper bound -- see
% watapac_twin_params. Modelled anyway, because it is what would dominate
% over a long deployment.
S.blockage_frac     = min(P.blockage_max, P.blockage_per_g * S.debris_caught_g);
S.Q_turbine_cms     = S.Q_cms .* (1 - S.blockage_frac);
S.Q_bypass_cms      = S.Q_cms .* S.blockage_frac;
S.Q_turbine_lpm     = S.Q_turbine_cms * 60000;

%% ===== Stage 3: cascade turbines =======================================
% The same water drives both runners in series, so each sees the full flow
% but only its share of the head. That is the claim the manuscript makes
% about the cascade, and the reason the two turbines measured nearly equal.
n = P.n_turbine;
S.head_m        = P.head_total_m * P.head_split(:)';
S.hydraulic_w   = zeros(numel(rain_mmh), n);
S.mech_w        = zeros(numel(rain_mmh), n);

for k = 1:n
    % P = rho * g * Q * H
    S.hydraulic_w(:,k) = P.rho * P.g * S.Q_turbine_cms(:) * S.head_m(k);
    S.mech_w(:,k)      = S.hydraulic_w(:,k) * P.eta_turbine;
end

S.hydraulic_total_w = sum(S.hydraulic_w, 2)';
S.mech_total_w      = sum(S.mech_w, 2)';

%% ===== Stage 4: alternator -> rectifier -> buck =========================
% Open-circuit AC, then the 3-phase bridge, which Appendix D omits. Two
% diodes conduct at any instant, so the bridge costs rect_v_drop volts AND
% rect_v_drop * I watts. At a ~6 V bus that is about a quarter of the output.
S.v_ac_oc       = P.kv_ac_per_lpm * S.Q_turbine_lpm;            % per turbine
S.v_dc_oc       = max(0, P.rect_ac_to_dc * S.v_ac_oc - P.rect_v_drop);

% Below the diode drop nothing conducts at all. A real cut-in threshold,
% absent from Appendix D, where output is linear in flow all the way to zero.
S.rect_conducting = (P.rect_ac_to_dc * S.v_ac_oc) > P.rect_v_drop;

S.gen_ac_w      = S.mech_total_w * P.eta_generator;
v_ac_bus        = max(P.rect_ac_to_dc * S.v_ac_oc, eps);
S.current_a     = S.rect_conducting .* S.gen_ac_w ./ v_ac_bus;
S.rect_loss_w   = S.current_a * P.rect_v_drop;
S.dc_w          = max(0, S.gen_ac_w - S.rect_loss_w) .* S.rect_conducting;
S.v_bus         = S.v_dc_oc;
S.power_kw      = S.dc_w / 1000;

%% ===== Stage 5: charge path ============================================
% The XL4015 is a STEP-DOWN converter. To charge the pack it needs an input
% above both its own minimum and the battery voltage plus dropout. At a 6 V
% bus and a 12.6 V pack, neither condition is met -- so the twin reports the
% charge path as dead rather than quietly charging the battery anyway.
S.buck_vin_required = max(P.buck_vin_min, P.batt_v_full + P.buck_dropout_v);
S.charge_path_ok    = S.v_bus >= S.buck_vin_required;
S.batt_charge_w     = S.dc_w .* S.charge_path_ok * P.eta_buck;
S.batt_charge_a     = S.batt_charge_w / P.batt_v_nominal;

%% ===== Stage 6: loads ==================================================
% LED strip at the firmware's brightness, plus everything else that has to
% stay powered for the monitoring system to exist at all. Appendix D counts
% only the LEDs.
S.led_on        = (S.Q_turbine_lpm >= P.flow_trigger_lpm) | (rain_mmh >= P.rain_thresh_mmh);
led_ma_each     = P.led_ma_quiescent + P.led_brightness * (P.led_ma_full - P.led_ma_quiescent);
S.led_w_when_on = P.n_led * led_ma_each / 1000 * P.led_volts;
S.led_w         = S.led_on * S.led_w_when_on;

S.base_load_w   = P.pi_watts + P.arduino_watts + P.sensor_watts;
S.load_total_w  = S.led_w + S.base_load_w;
S.net_w         = S.batt_charge_w - S.load_total_w;

%% ===== What the sensors would actually report ==========================
% The twin's own instrument model. A MAX471 reading 1 V/A into a 10-bit ADC
% quantises to current_lsb_a, and the firmware zeroes anything under its
% deadband. This is what makes the measured results explainable.
S.current_lsb_a      = P.current_lsb_a;
S.current_in_counts  = S.current_a / P.current_lsb_a;
quantised            = floor(S.current_a / P.current_lsb_a) * P.current_lsb_a;
S.current_reported_a = quantised .* (quantised >= P.current_deadband_a);
S.power_reported_w   = S.current_reported_a .* S.v_bus;
end


%% ------------------------------------------------------------------------
function [a, b] = expandToMatch(a, b)
%EXPANDTOMATCH  Allow any mix of scalars and equal-length vectors.
a = a(:)';
b = b(:)';
if isscalar(a) && ~isscalar(b); a = repmat(a, size(b)); end
if isscalar(b) && ~isscalar(a); b = repmat(b, size(a)); end
if numel(a) ~= numel(b)
    error('watapac_plant:sizeMismatch', ...
        'rain_mmh has %d elements and debris_g has %d; they must match or be scalar.', ...
        numel(a), numel(b));
end
end
