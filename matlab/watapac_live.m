function out = watapac_live(varargin)
%WATAPAC_LIVE  Run the Simulink twin alongside the physical prototype.
%
%   The bridge between the Raspberry Pi and the digital twin. Once a second
%   it fetches /api/status, pushes the live readings into the running
%   Simulink model, computes what the twin predicts, logs both, and raises
%   an alarm when they part company.
%
%       Arduino -> Pi (Flask) -> [this] -> Simulink -> Scope
%
%   COMMANDS
%       watapac_live('Url', 'http://192.168.1.50:5000')   start
%       watapac_live('stop')                              stop
%       watapac_live('status')                            is it running
%       watapac_live('report')                            MAE/RMSE/MAPE + latency
%
%   OPTIONS when starting
%       'Url'       Pi address, with or without /api/status  (required)
%       'Model'     Simulink model to drive (default 'watapac_twin')
%       'Simulink'  push to the model at all (default true)
%       'Log'       write a CSV (default true)
%       'LogDir'    where (default <this folder>/live_logs)
%       'Quiet'     suppress the per-second console line (default false)
%
%   ON MEASURING LATENCY
%
%   The obvious approach is to subtract the Pi's packet timestamp from the
%   laptop's clock. That does not measure latency: it measures the
%   DISAGREEMENT BETWEEN TWO CLOCKS. A Raspberry Pi has no battery-backed
%   real-time clock, so unless it has reached an NTP server since boot its
%   wall clock can be out by hours, and the "latency" would come back
%   negative or enormous.
%
%   Two skew-free numbers are used instead:
%
%     rtt_ms    round trip, measured entirely on this laptop with tic/toc
%               around the webread
%     pi_age_s  how stale the reading already was when the Pi served it,
%               measured entirely on the Pi with its monotonic clock
%
%   End-to-end staleness is pi_age_s + rtt_ms/2 + the update time, and every
%   term is measured on one machine against itself.
%
%   See also WATAPAC_LIVE_SAMPLE, WATAPAC_COMPARE, WATAPAC_BUILD_TWIN.

persistent STATE

if isempty(STATE); STATE = freshState(); end
out = [];

% --- command form -------------------------------------------------------
if nargin == 1 && ischar(varargin{1})
    switch lower(varargin{1})
        case 'stop';   STATE = doStop(STATE);   return;
        case 'status'; out = doStatus(STATE);   return;
        case 'report'; out = doReport(STATE);   return;
        otherwise
            error('watapac_live:badCommand', ...
                'Unknown command "%s". Use stop, status or report.', varargin{1});
    end
end

% --- start --------------------------------------------------------------
opts = parseOptions(varargin);
if ~isempty(STATE.timer)
    fprintf('  Already running. Stop it first:  watapac_live(''stop'')\n');
    return;
end

STATE = freshState();
STATE.opts = opts;
STATE.P    = opts.Params;

rule();
fprintf(' WATAPAC LIVE  -  prototype alongside the digital twin\n');
rule();
fprintf('  Pi      : %s\n', opts.Url);
fprintf('  period  : %.1f s\n', STATE.P.live_period_s);
fprintf('  alarm   : |measured - predicted| > %g %%\n', STATE.P.live_alarm_pct);

% --- one probe before committing, so a wrong address fails now ----------
fprintf('\n  probing...\n');
[d, rtt, err] = fetchOnce(opts.Url, STATE.P.live_timeout_s);
if ~isempty(err)
    error('watapac_live:unreachable', ...
        ['Cannot reach %s\n  %s\n\n' ...
         'Check that:\n' ...
         '  - the Pi is running   python3 pi/watapac_server.py\n' ...
         '  - this laptop and the Pi are on the same network\n' ...
         '  - the address is the Pi''s IP, not localhost\n' ...
         '  Try it in a browser first.'], opts.Url, err);
end
fprintf('  reached the Pi in %.0f ms\n', rtt*1000);
if isfield(d, 'arduinoConnected') && ~d.arduinoConnected
    fprintf(2, '  NOTE: the Pi is up but reports no Arduino data.\n');
    fprintf(2, '  The twin will run and log, with measurements as NaN.\n');
end

% --- Simulink ------------------------------------------------------------
if opts.Simulink
    STATE.simOk = startModel(opts.Model, STATE.P);
    if ~STATE.simOk
        fprintf(2, '  Continuing without the Simulink push; logging still works.\n');
    end
end

% --- logging -------------------------------------------------------------
if opts.Log
    STATE.logFile = openLog(opts.LogDir);
    fprintf('  logging : %s\n', STATE.logFile);
end

% --- the timer -----------------------------------------------------------
% BusyMode drop, not queue: if the Pi stalls, the next tick is skipped
% rather than stacking up callbacks that then all fire at once.
STATE.timer = timer( ...
    'Name',          'watapac_live', ...
    'ExecutionMode', 'fixedRate', ...
    'Period',        STATE.P.live_period_s, ...
    'BusyMode',      'drop', ...
    'TimerFcn',      @(~,~) tick(), ...
    'ErrorFcn',      @(~,e) fprintf(2, '  timer error: %s\n', e.Data.message));
start(STATE.timer);

fprintf('\n  running. stop with:  watapac_live(''stop'')\n');
rule();
out = STATE.timer;

%% ========================================================================
%  The per-second callback. Nested, so it shares STATE.
%  ========================================================================
    function tick()
        [dd, rttS, errS] = fetchOnce(STATE.opts.Url, STATE.P.live_timeout_s);
        STATE.ticks = STATE.ticks + 1;

        if ~isempty(errS)
            STATE.misses = STATE.misses + 1;
            if ~STATE.opts.Quiet
                fprintf('  [%4d] no data (%s) - holding last value\n', ...
                    STATE.ticks, firstLine(errS));
            end
            return;
        end

        S = watapac_live_sample(dd, STATE.P);
        S.rtt_ms = rttS * 1000;
        STATE.last = S;

        if STATE.simOk
            STATE.simOk = pushToModel(STATE.opts.Model, S);
        end
        if ~isempty(STATE.logFile)
            appendLog(STATE.logFile, S);
        end
        if ~STATE.opts.Quiet
            printLine(STATE.ticks, S);
        end
        if S.alarm
            STATE.alarms = STATE.alarms + 1;
        end
    end
end


%% ========================================================================
%  Network
%  ========================================================================

function [d, rtt, err] = fetchOnce(url, timeout)
%FETCHONCE  One GET, with the round trip timed on this machine only.
d = []; err = '';
t0 = tic;
try
    raw = webread(url, httpOptions(timeout));
    d = asStruct(raw);
catch e
    err = e.message;
end
rtt = toc(t0);
end


function d = asStruct(raw)
%ASSTRUCT  webread gives a struct or the raw text; accept either.
%
%   MATLAB decodes JSON automatically when the server sets
%   Content-Type: application/json, and hands back the undecoded text when
%   it does not. Decoding here rather than relying on the header means a
%   misconfigured server degrades to working instead of to a silent field
%   of NaN, which is what a missing decode looks like downstream.
if isstruct(raw)
    d = raw;
    return;
end
if isstring(raw); raw = char(raw); end
if ischar(raw)
    d = jsondecode(raw);
    return;
end
error('watapac_live:badResponse', ...
    'The Pi returned a %s, not JSON. Open the URL in a browser to see what it serves.', ...
    class(raw));
end


function o = httpOptions(timeout)
%HTTPOPTIONS  weboptions that survive a fractional timeout.
%
%   MATLAB takes a fractional Timeout; some builds reject anything but a
%   whole number. A sub-period timeout is worth keeping where it is allowed,
%   because it guarantees the callback returns before the next tick, so try
%   the exact value first and round up only if it is refused.
persistent useWhole
if isempty(useWhole); useWhole = false; end

if ~useWhole
    try
        o = weboptions('Timeout', timeout, 'ContentType', 'json');
        return;
    catch
        useWhole = true;   % decided once, not re-tried every second
    end
end
o = weboptions('Timeout', max(1, ceil(timeout)), 'ContentType', 'json');
end


function url = normaliseUrl(url)
url = char(url);
url = regexprep(url, '/+$', '');
if isempty(regexp(url, '/api/status$', 'once'))
    url = [url '/api/status'];
end
if isempty(regexp(url, '^https?://', 'once'))
    url = ['http://' url];
end
end


%% ========================================================================
%  Simulink
%  ========================================================================

function ok = startModel(mdl, P)
%STARTMODEL  Open the twin and run it in real time.
%
%   Pacing is what makes it "real time": one simulation second per wall
%   clock second, so the Scope advances at the same rate as the prototype.
ok = false;
try
    if ~bdIsLoaded(mdl)
        load_system(mdl);
    end
    open_system(mdl);
    set_param(mdl, 'StopTime', 'inf');
    set_param(mdl, 'EnablePacing', 'on', 'PacingRate', '1');
    if ~strcmp(get_param(mdl, 'SimulationStatus'), 'running')
        set_param(mdl, 'SimulationCommand', 'start');
    end
    ok = true;
    fprintf('  simulink: %s running with pacing at 1x\n', mdl);
catch e
    fprintf(2, '  simulink: could not start %s\n    %s\n', mdl, e.message);
    fprintf(2, '  Build it first:  watapac_build_twin\n');
end
end


function ok = pushToModel(mdl, S)
%PUSHTOMODEL  Write the live readings into the model's Constant blocks.
%
%   set_param on a Constant's Value is tunable in Normal mode, so this takes
%   effect at the next major step. It is also the part most likely to fail
%   if the model was stopped by hand, so a failure disables further pushes
%   rather than printing once a second forever.
ok = true;
targets = { 'Flow_In',       S.flow_lpm
            'T1_Measured',   S.t1_meas_w
            'T2_Measured',   S.t2_meas_w
            'Batt_Measured', S.batt_pct };
for i = 1:size(targets,1)
    v = targets{i,2};
    if isnan(v); continue; end          % never push a fabricated zero
    blk = [mdl '/' targets{i,1}];
    try
        set_param(blk, 'Value', num2str(v, '%.6g'));
    catch e
        fprintf(2, '\n  simulink push stopped: %s\n    %s\n', blk, firstLine(e.message));
        fprintf(2, '  Logging continues. Restart the model and re-run to resume.\n');
        ok = false;
        return;
    end
end
end


%% ========================================================================
%  Logging
%  ========================================================================

function file = openLog(dir)
if ~exist(dir, 'dir'); mkdir(dir); end
file = fullfile(dir, ['live_' datestr(now, 'yyyymmdd_HHMMSS') '.csv']);
fid = fopen(file, 'w');
fprintf(fid, ['wallclock,rtt_ms,pi_age_s,flow_lpm,' ...
    'v_meas,i_meas,p_meas_w,t1_meas_w,t2_meas_w,batt_pct,' ...
    'v_pred,i_pred,p_pred_w,t1_pred_w,t2_pred_w,' ...
    'err_p_w,pct_p,alarm\n']);
fclose(fid);
end


function appendLog(file, S)
fid = fopen(file, 'a');
if fid < 0; return; end
fprintf(fid, '%.3f,%.1f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d\n', ...
    S.wallclock, S.rtt_ms, n(S.pi_age_s), n(S.flow_lpm), ...
    n(S.voltage_v), n(S.current_a), n(S.power_w), n(S.t1_meas_w), n(S.t2_meas_w), n(S.batt_pct), ...
    n(S.pred_voltage_v), n(S.pred_current_a), n(S.pred_power_w), n(S.t1_pred_w), n(S.t2_pred_w), ...
    n(S.err_power_w), n(S.pct_power), S.alarm);
fclose(fid);
end


function s = n(v)
%N  A number for the CSV, or an empty cell. Empty reads as missing in both
%   MATLAB's readtable and pandas; a 0 would read as a measurement.
if isnan(v); s = ''; else; s = sprintf('%.6g', v); end
end


%% ========================================================================
%  Commands
%  ========================================================================

function STATE = doStop(STATE)
if isempty(STATE.timer)
    fprintf('  Not running.\n');
    return;
end
try; stop(STATE.timer); delete(STATE.timer); catch; end
if STATE.opts.Simulink
    try; set_param(STATE.opts.Model, 'SimulationCommand', 'stop'); catch; end
end
rule();
fprintf(' stopped after %d ticks  (%d missed, %d alarms)\n', ...
    STATE.ticks, STATE.misses, STATE.alarms);
if ~isempty(STATE.logFile)
    fprintf(' log: %s\n', STATE.logFile);
    fprintf(' metrics:  watapac_live(''report'')\n');
end
rule();
lastLog = STATE.logFile;
STATE = freshState();
STATE.logFile = lastLog;   % keep it so 'report' still has something to read
end


function s = doStatus(STATE)
s.running = ~isempty(STATE.timer);
s.ticks = STATE.ticks; s.misses = STATE.misses; s.alarms = STATE.alarms;
s.logFile = STATE.logFile;
if s.running
    fprintf('  running: %d ticks, %d missed, %d alarms\n', s.ticks, s.misses, s.alarms);
else
    fprintf('  not running.\n');
end
end


function R = doReport(STATE)
%DOREPORT  MAE, RMSE, MAPE and the latency distribution from the log.
R = [];
if isempty(STATE.logFile) || ~exist(STATE.logFile, 'file')
    fprintf('  No log to report on. Start a run with a Url first.\n');
    return;
end
T = readtable(STATE.logFile);
if height(T) == 0
    fprintf('  The log is empty.\n');
    return;
end

rule();
fprintf(' LIVE RUN REPORT   %s\n', STATE.logFile);
fprintf(' %d samples\n', height(T));
rule();

reportSignal('combined power (W)', T.p_meas_w, T.p_pred_w);
if any(~isnan(T.t1_meas_w)); reportSignal('turbine 1 (W)', T.t1_meas_w, T.t1_pred_w); end
if any(~isnan(T.t2_meas_w)); reportSignal('turbine 2 (W)', T.t2_meas_w, T.t2_pred_w); end
reportSignal('bus voltage (V)', T.v_meas, T.v_pred);

fprintf('\n LATENCY\n');
fprintf('   round trip     median %.0f ms, 95th %.0f ms, worst %.0f ms\n', ...
    median(T.rtt_ms, 'omitnan'), pct95(T.rtt_ms), max(T.rtt_ms));
if any(~isnan(T.pi_age_s))
    fprintf('   data age at Pi median %.0f ms\n', 1000*median(T.pi_age_s, 'omitnan'));
    fprintf('   end to end     median %.0f ms  (Pi age + half the round trip)\n', ...
        1000*median(T.pi_age_s, 'omitnan') + median(T.rtt_ms, 'omitnan')/2);
end
fprintf('\n   Both terms are measured on one machine against itself, so\n');
fprintf('   neither depends on the Pi''s clock agreeing with this one.\n');

fprintf('\n ALARMS\n');
fprintf('   %d of %d samples over threshold (%.0f %%)\n', ...
    sum(T.alarm == 1), height(T), 100*sum(T.alarm == 1)/height(T));
rule();
R.table = T;
end


function reportSignal(name, meas, pred)
ok = ~isnan(meas) & ~isnan(pred);
if ~any(ok); return; end
m = meas(ok); p = pred(ok);
e = p - m;
fprintf('\n %s   n = %d\n', name, numel(m));
fprintf('   measured mean %.5g,  predicted mean %.5g\n', mean(m), mean(p));
fprintf('   MAE  %.5g\n', mean(abs(e)));
fprintf('   RMSE %.5g\n', sqrt(mean(e.^2)));
nz = abs(m) > eps;
if any(nz)
    fprintf('   MAPE %.1f %%\n', 100 * mean(abs(e(nz) ./ m(nz))));
end
end


function v = pct95(x)
x = sort(x(~isnan(x)));
if isempty(x); v = NaN; return; end
v = x(max(1, ceil(0.95 * numel(x))));
end


%% ========================================================================
%  Plumbing
%  ========================================================================

function S = freshState()
S = struct('timer', [], 'opts', [], 'P', [], 'logFile', '', 'simOk', false, ...
           'ticks', 0, 'misses', 0, 'alarms', 0, 'last', []);
end


function printLine(k, S)
flag = '   ';
if S.alarm; flag = ' ! '; end
fprintf('  [%4d]%s flow %6.3f L/min | meas %8.4f W | twin %9.6f W | %+7.1f %% | %3.0f ms\n', ...
    k, flag, S.flow_lpm, S.power_w, S.pred_power_w, S.pct_power, S.rtt_ms);
end


function opts = parseOptions(args)
here = fileparts(mfilename('fullpath'));
opts = struct('Url', '', 'Model', 'watapac_twin', 'Simulink', true, ...
              'Log', true, 'LogDir', fullfile(here, 'live_logs'), ...
              'Quiet', false, 'Params', []);
if mod(numel(args), 2) ~= 0
    error('watapac_live:badArgs', 'Options must be name-value pairs.');
end
for i = 1:2:numel(args)
    name = char(args{i});
    if ~isfield(opts, name)
        error('watapac_live:badArgs', 'Unknown option "%s". Valid: %s.', ...
            name, strjoin(fieldnames(opts)', ', '));
    end
    opts.(name) = args{i+1};
end
if isempty(opts.Url)
    error('watapac_live:noUrl', ...
        ['A Pi address is required:\n' ...
         '  watapac_live(''Url'', ''http://192.168.1.50:5000'')\n' ...
         'Find the Pi''s address with  hostname -I  on the Pi itself.']);
end
opts.Url = normaliseUrl(opts.Url);
if isempty(opts.Params); opts.Params = watapac_twin_params(); end
end


function s = firstLine(msg)
idx = find(msg == sprintf('\n'), 1);
if isempty(idx); s = msg; else; s = msg(1:idx-1); end
end


function rule()
fprintf('%s\n', repmat('=', 1, 74));
end
