function T = watapac_simulate(t, rain_mmh, P)
%WATAPAC_SIMULATE  Run the twin over time, in plain MATLAB.
%
%   T = WATAPAC_SIMULATE(t, rain_mmh, P)
%
%   Adds the two things watapac_plant cannot express, because they have
%   memory: the 15 s LED hold and the battery state of charge.
%
%   This is the reference the Simulink model is checked against. Having it
%   in plain MATLAB means the time-dependent behaviour can be tested without
%   a Simulink licence, which is the whole reason it exists separately.
%
%   t         column or row vector of times, seconds, increasing
%   rain_mmh  rainfall at each time, same length (or scalar)
%
%   Returns every field of watapac_plant plus:
%     led_on       logical, after the hold
%     soc          state of charge, 0 to 1
%     batt_volts   pack terminal voltage from the 3S curve
%     energy_kwh   cumulative generated energy
%     net_w        charge power minus total load

if nargin < 3 || isempty(P); P = watapac_twin_params(); end
t = t(:)';
if isscalar(rain_mmh); rain_mmh = repmat(rain_mmh, size(t)); end
rain_mmh = rain_mmh(:)';
assert(numel(t) == numel(rain_mmh), ...
    'watapac_simulate: t has %d points, rain_mmh has %d.', numel(t), numel(rain_mmh));
assert(all(diff(t) > 0), 'watapac_simulate: t must be strictly increasing.');

n = numel(t);
S = watapac_plant(rain_mmh, P.debris_total_g, P);

T = S;
T.t = t;
T.led_on     = false(1, n);
T.soc        = zeros(1, n);
T.batt_volts = zeros(1, n);
T.energy_kwh = zeros(1, n);
T.net_w      = zeros(1, n);

% --- LED hold ------------------------------------------------------------
% The firmware re-arms a 15 s timer every time flow or rain crosses the
% threshold, so the strip stays lit for 15 s after the last trigger rather
% than switching off the instant the flow drops.
last_trigger = -inf;
for k = 1:n
    if S.led_on(k)
        last_trigger = t(k);
    end
    T.led_on(k) = (t(k) - last_trigger) <= P.light_hold_s;
end

led_w = T.led_on * S.led_w_when_on;
base_w = P.pi_watts + P.arduino_watts + P.sensor_watts;
T.load_total_w = led_w + base_w;
T.net_w = S.batt_charge_w - T.load_total_w;

% --- Battery state of charge --------------------------------------------
% Integrated with the limits applied to the STATE, not to a copy of it.
% Clipping the output of a free-running integrator leaves the state winding
% past the rail, and the display then lags reality by however long it takes
% to climb back out.
cap_j = P.batt_capacity_wh * 3600;
soc = P.soc_initial;
energy_j = 0;
T.soc(1) = soc;
for k = 2:n
    dt = t(k) - t(k-1);
    soc = soc + 0.5*(T.net_w(k-1) + T.net_w(k)) * dt / cap_j;
    soc = min(1, max(0, soc));
    T.soc(k) = soc;
    energy_j = energy_j + 0.5*(S.dc_w(k-1) + S.dc_w(k)) * dt;
    T.energy_kwh(k) = energy_j / 3.6e6;
end

T.batt_volts = P.batt_v_empty + T.soc * (P.batt_v_full - P.batt_v_empty);
T.led_w = led_w;
end
