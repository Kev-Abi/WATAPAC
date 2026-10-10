function S = watapac_live_sample(d, P)
%WATAPAC_LIVE_SAMPLE  Turn one /api/status reply into a measured/predicted pair.
%
%   S = WATAPAC_LIVE_SAMPLE(d, P)
%
%   d is the struct webread returns from the Pi. P is watapac_twin_params.
%
%   Pure function, no I/O and no Simulink, so the whole mapping from JSON to
%   comparison can be tested without a Pi or a licence. watapac_live does the
%   network and the set_param; this decides what the numbers mean.
%
%   The twin's prediction is computed HERE rather than read back out of the
%   running Simulink model. The Simulink model is the live display; this is
%   the arithmetic of record. If a set_param push is dropped mid-demo the
%   logged comparison is still correct.
%
%   Returns a struct with, for each signal, the measured value, the twin's
%   prediction, and the error. Anything the Pi could not measure comes
%   through as NaN, never as zero.

if nargin < 2 || isempty(P); P = watapac_twin_params(); end

S.ok        = isstruct(d) && isfield(d, 'arduinoConnected') && logical(d.arduinoConnected);
S.wallclock = nowEpoch();

% --- measured -----------------------------------------------------------
% The Pi sends the em dash for anything it did not measure, so a field can
% arrive as text. numOrNaN turns that into NaN; treating it as 0 would put a
% fake reading into the comparison.
S.flow_lpm   = field(d, 'flowRate');
S.voltage_v  = field(d, 'voltage');
S.current_a  = field(d, 'current');
S.power_w    = watts(field(d, 'power'));      % the Pi reports kW
S.batt_pct   = field(d, 'batteryPercent');
S.t1_meas_w  = field(d, 't1Power');           % already W, and optional
S.t2_meas_w  = field(d, 't2Power');

% --- staleness ----------------------------------------------------------
% readingAgeSeconds is measured on the Pi with its own monotonic clock, so
% it is immune to any disagreement between the Pi's wall clock and this
% laptop's. Subtracting one machine's timestamp from the other's would
% measure clock skew, not latency -- see watapac_live.
S.pi_age_s = field(d, 'readingAgeSeconds');

% --- predicted ----------------------------------------------------------
% Driven by the MEASURED flow, so this tests the turbine and electrical
% model and nothing upstream of it -- the same staging watapac_compare uses.
if isnan(S.flow_lpm) || S.flow_lpm <= 0
    S.flow_for_model = NaN;
    blank = NaN;
    S.pred_power_w = blank; S.pred_voltage_v = blank; S.pred_current_a = blank;
    S.t1_pred_w = blank; S.t2_pred_w = blank;
    S.pred_reported_a = blank;
else
    S.flow_for_model = S.flow_lpm;
    rain_equiv = S.flow_lpm / (P.C_runoff * P.A_catch_eff / 3.6e6 * 60000);
    T = watapac_plant(rain_equiv, P.debris_total_g, P);

    S.pred_power_w   = T.dc_w;
    S.pred_voltage_v = T.v_bus;
    S.pred_current_a = T.current_a;
    % The cascade shares the head, so each turbine's share of the output is
    % its share of the head.
    S.t1_pred_w = T.dc_w * P.head_split(1);
    S.t2_pred_w = T.dc_w * P.head_split(min(2, numel(P.head_split)));
    % What the MAX471 and the firmware would print for that current.
    S.pred_reported_a = T.current_reported_a;
end

% --- errors -------------------------------------------------------------
S.err_power_w   = S.pred_power_w   - S.power_w;
S.err_voltage_v = S.pred_voltage_v - S.voltage_v;
S.err_t1_w      = S.t1_pred_w      - S.t1_meas_w;
S.err_t2_w      = S.t2_pred_w      - S.t2_meas_w;

S.pct_power = 100 * S.err_power_w / S.power_w;

% --- alarm --------------------------------------------------------------
% A live twin earns its keep by shouting when measurement and model part
% company: a blocked mesh, a stalled runner, a failed sensor. The threshold
% is relative, because an absolute watt figure means nothing across the
% range of flows this unit sees.
S.alarm_threshold_pct = P.live_alarm_pct;
S.alarm = ~isnan(S.pct_power) && abs(S.pct_power) > S.alarm_threshold_pct;
end


%% ------------------------------------------------------------------------
function v = field(d, name)
%FIELD  A numeric field, or NaN if absent or sent as the em-dash placeholder.
v = NaN;
if ~isstruct(d) || ~isfield(d, name); return; end
raw = d.(name);
if isnumeric(raw) && isscalar(raw)
    v = double(raw);
elseif islogical(raw) && isscalar(raw)
    v = double(raw);
end
% Anything else -- the em dash, a string, an empty -- stays NaN.
end


function w = watts(kw)
w = kw * 1000;
end


function t = nowEpoch()
%NOWEPOCH  Seconds since the epoch, without needing posixtime().
t = (now - datenum(1970,1,1)) * 86400;
end
