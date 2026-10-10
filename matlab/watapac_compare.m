function R = watapac_compare(varargin)
%WATAPAC_COMPARE  Arduino measurements against the digital twin, stage by stage.
%
%   This is the Real-Time Data Sync the Integration Guide asks for: measured
%   telemetry and simulated prediction placed side by side so the twin can
%   be judged against the physical unit.
%
%   Usage
%       watapac_compare                                  % the five trials
%       watapac_compare('Log', '../pi/logs')             % logged 1 Hz CSV
%       watapac_compare('Url', 'http://192.168.1.42:5000')
%       watapac_compare('Plot', false)
%
%   WHY THE COMPARISON IS STAGED
%
%   The obvious thing is to feed rainfall in at one end and compare power at
%   the other. Do that and a single number comes out, and it tells you
%   nothing: if the twin is wrong you cannot see WHERE it went wrong,
%   because an error in the runoff model arrives at the turbine as a flow
%   error and leaves as a power error.
%
%   So each stage is driven by the MEASURED input to that stage, not by the
%   previous stage's prediction:
%
%     Stage 1   rainfall  -> flow      driven by the known 15 mm/h
%     Stage 3-4 flow      -> power     driven by the MEASURED flow
%
%   An error then stays in the stage that caused it, and the report says
%   which stage agrees and which does not.
%
%   METRICS
%     bias    mean(sim - obs), in the signal's own units. Sign matters:
%             positive means the twin predicts high.
%     RMSE    root mean square error, same units.
%     % error relative to the measured mean.
%     NSE     Nash-Sutcliffe efficiency, the standard goodness-of-fit in
%             hydrology. 1 is perfect; 0 means the model is no better than
%             simply predicting the measured mean; below 0 is worse than
%             that. Reported because this is a drainage study.
%
%   See also WATAPAC_PLANT, WATAPAC_VALIDATE, WATAPAC_LOAD_LOG.

opts = parseOptions(varargin);
P = opts.Params;

rule('=');
fprintf(' WATAPAC  -  MEASURED vs DIGITAL TWIN\n');
rule('=');

if ~isempty(opts.Log) || ~isempty(opts.Url)
    [obs, srcLabel] = loadFromTelemetry(opts);
else
    [obs, srcLabel] = loadFromTrials();
end
fprintf(' source : %s\n', srcLabel);
fprintf(' samples: %d\n', numel(obs.flow_lpm));
rule('=');

R.source = srcLabel;
R.n = numel(obs.flow_lpm);
R.observed = obs;

%% =======================================================================
%  STAGE 1  -  rainfall to flow
%  =======================================================================
section('STAGE 1  -  RAINFALL TO FLOW   (YF-S201 vs rational method)');

S1 = watapac_plant(obs.rain_mmh, P.debris_total_g, P);
R.stage1 = compareSignal('flow rate', 'L/min', obs.flow_lpm, S1.Q_lpm);
fprintf('\n  Driven by the rainfall intensity. This tests the catchment\n');
fprintf('  model and nothing downstream of it.\n');

%% =======================================================================
%  STAGE 3-4  -  flow to electrical output
%  =======================================================================
section('STAGE 3-4  -  FLOW TO ELECTRICAL OUTPUT   (MAX471 vs turbine model)');
fprintf('  Driven by the MEASURED flow, so a stage 1 error cannot leak in.\n\n');

% Back out the rainfall that produces each measured flow, then run the twin
% from there. Using the measured flow directly as the stage 3 input is what
% isolates the turbine and electrical models.
rain_equiv = obs.flow_lpm / (P.C_runoff * P.A_catch_eff / 3.6e6 * 60000);
S2 = watapac_plant(rain_equiv, P.debris_total_g, P);
R.twin = S2;

% Sanity: the twin must reproduce the flow it was handed.
assert(max(abs(S2.Q_lpm - obs.flow_lpm)) < 1e-9, ...
    'watapac_compare: the equivalent-rainfall inversion did not round-trip.');

R.stage4.voltage = compareSignal('bus voltage', 'V', obs.voltage_v, S2.v_bus);
R.stage4.current = compareSignal('current', 'A', obs.current_a, S2.current_a);
R.stage4.power   = compareSignal('power', 'W', obs.power_w, S2.dc_w);

%% =======================================================================
%  What the sensor would have reported
%  =======================================================================
section('SENSOR EMULATION  -  what the Arduino SHOULD have printed');
fprintf('  The twin carries a model of the MAX471 and the firmware, so it\n');
fprintf('  predicts the READING and not only the true current.\n\n');
fprintf('  %-28s %12s %12s\n', 'quantity', 'twin', 'Arduino');
fprintf('  %-28s %12.4f %12.4f\n', 'true current (mA)', mean(S2.current_a)*1000, NaN);
fprintf('  %-28s %12.3f %12s\n', 'in ADC counts', mean(S2.current_in_counts), '-');
fprintf('  %-28s %12.3f %12.3f\n', 'reported current (A)', ...
    mean(S2.current_reported_a), mean(obs.current_a));
fprintf('\n  The firmware deadband is %.0f mA. A correctly calibrated sensor\n', ...
    P.current_deadband_a*1000);
fprintf('  would report %.3f A here; the Arduino reported %.3f A.\n', ...
    mean(S2.current_reported_a), mean(obs.current_a));

%% =======================================================================
%  Verdict
%  =======================================================================
section('WHICH STAGE AGREES');
verdictRow('1  rainfall -> flow',     R.stage1);
verdictRow('4  flow -> bus voltage',  R.stage4.voltage);
verdictRow('4  flow -> current',      R.stage4.current);
verdictRow('4  flow -> power',        R.stage4.power);

[~, l1] = classify(R.stage1);
[~, lv] = classify(R.stage4.voltage);
[~, lp] = classify(R.stage4.power);

fprintf('\n');
if l1 >= 2
    fprintf('  Stage 1 diverges, so nothing downstream can be read yet. The\n');
    fprintf('  flow entering the turbine is not what the twin thinks it is;\n');
    fprintf('  recalibrate A_catch_eff in watapac_twin_params first.\n');
elseif lp >= 2
    fprintf('  The hydraulic side agrees and the electrical side does not.\n');
    fprintf('  Flow is within %.1f %% and bus voltage within %.1f %%, but power\n', ...
        abs(R.stage1.pct_error), abs(R.stage4.voltage.pct_error));
    fprintf('  is out by %.1f %%.\n\n', abs(R.stage4.power.pct_error));
    fprintf('  That pattern localises the problem. The catchment model, the\n');
    fprintf('  turbine geometry and the generator voltage are all right; what\n');
    fprintf('  does not follow is the CURRENT, and therefore the watts. Since\n');
    fprintf('  voltage agrees to %.1f %% and current is out by %.1f %%, the\n', ...
        abs(R.stage4.voltage.pct_error), abs(R.stage4.current.pct_error));
    fprintf('  fault is in the current measurement rather than in the turbine.\n');
    fprintf('  Run watapac_validate for the energy audit behind that.\n');
elseif lv >= 2
    fprintf('  Flow agrees but bus voltage does not. Recalibrate\n');
    fprintf('  kv_ac_per_lpm in watapac_twin_params against a measured\n');
    fprintf('  open-circuit voltage.\n');
else
    fprintf('  Every stage agrees within tolerance.\n');
end

%% =======================================================================
if opts.Plot
    % S1 for flow, S2 for everything electrical. Plotting S2's flow would
    % show a perfect match by construction -- S2 was driven BY the measured
    % flow -- which looks like agreement and is really a round-trip check.
    makePlots(obs, S1, S2, opts.PlotFile);
end
rule('=');
fprintf('\n');
end


%% ========================================================================
%  Data sources
%  ========================================================================

function [obs, label] = loadFromTrials()
%LOADFROMTRIALS  The five recorded trials, one point each.
D = watapac_trial_data();
P = watapac_twin_params();
obs.rain_mmh  = repmat(P.rain_yellow_mmh, 1, P.n_trials);
obs.flow_lpm  = D.wat.flow_lpm;
obs.voltage_v = (D.t1.voltage_v + D.t2.voltage_v) / 2;   % parallel bus
obs.current_a = D.t1.current_a + D.t2.current_a;         % parallel sums
obs.power_w   = D.combined.power_w;
label = sprintf('Appendix G, %d trials of %d s', P.n_trials, D.trial_seconds);
end


function [obs, label] = loadFromTelemetry(opts)
%LOADFROMTELEMETRY  Logged 1 Hz rows from the Pi.
if ~isempty(opts.Url)
    T = watapac_load_log('Url', opts.Url, 'Hours', opts.Hours);
    label = sprintf('live Pi at %s, last %g h', opts.Url, opts.Hours);
else
    T = watapac_load_log('Dir', opts.Log, 'Hours', opts.Hours);
    label = sprintf('CSV in %s, last %g h', opts.Log, opts.Hours);
end
if isempty(T)
    error('watapac_compare:noData', ...
        ['No logged rows found.\n' ...
         'The Pi writes them only while an Arduino is actually sending, ' ...
         'and only with WATAPAC_LOG_INTERVAL > 0.']);
end

P = watapac_twin_params();
keep = ~isnan(T.flowRate) & ~isnan(T.voltage) & ~isnan(T.current);
if ~any(keep)
    error('watapac_compare:noUsableRows', ...
        'Rows were found but none has flow, voltage and current together.');
end
T = T(keep, :);

obs.flow_lpm  = T.flowRate(:)';
obs.voltage_v = T.voltage(:)';
obs.current_a = T.current(:)';
obs.power_w   = obs.voltage_v .* obs.current_a;
% The log records rain as a flag, not an intensity; the trial condition is
% the only intensity known, so it stands in for the stage 1 drive.
obs.rain_mmh  = repmat(P.rain_yellow_mmh, 1, numel(obs.flow_lpm));
label = sprintf('%s  (%d usable rows)', label, numel(obs.flow_lpm));
end


%% ========================================================================
%  Comparison
%  ========================================================================

function C = compareSignal(name, unit, obs, sim)
%COMPARESIGNAL  One measured signal against its predicted counterpart.
obs = obs(:)'; sim = sim(:)';
if isscalar(sim); sim = repmat(sim, size(obs)); end

C.name = name; C.unit = unit;
C.obs_mean = mean(obs);
C.obs_sd   = stddev(obs);
C.sim_mean = mean(sim);
C.bias     = mean(sim - obs);
C.rmse     = sqrt(mean((sim - obs).^2));
C.mae      = mean(abs(sim - obs));
C.pct_error = 100 * C.bias / C.obs_mean;

% Nash-Sutcliffe, but only where it means something.
%
% NSE compares the model against "just predict the mean". If the twin's
% prediction does not vary -- which happens whenever every sample was
% driven by the same input, as in the five trials at one rainfall level --
% then the model IS a constant, NSE is 0 by construction, and reporting
% "worse than predicting the mean" would be a statement about the
% experiment design rather than about the twin. Say so instead.
denom = sum((obs - mean(obs)).^2);
C.sim_varies = stddev(sim) > 1e-12 * max(abs(C.sim_mean), eps);
if denom > 0 && C.sim_varies
    C.nse = 1 - sum((sim - obs).^2) / denom;
else
    C.nse = NaN;
end
C.ratio = C.sim_mean / C.obs_mean;

fprintf('\n  %s (%s)\n', upper(name), unit);
fprintf('    measured   %10.5g  (SD %.4g, n = %d)\n', C.obs_mean, C.obs_sd, numel(obs));
fprintf('    twin       %10.5g\n', C.sim_mean);
fprintf('    bias       %+10.5g   %+.1f %%\n', C.bias, C.pct_error);
fprintf('    RMSE       %10.5g      MAE %.5g\n', C.rmse, C.mae);
if ~isnan(C.nse)
    fprintf('    NSE        %10.3f   %s\n', C.nse, nseWord(C.nse));
elseif ~C.sim_varies
    fprintf('    NSE                 n/a   (the twin predicts one constant here,\n');
    fprintf('                              because every sample had the same input.\n');
    fprintf('                              The scatter is the rainfall simulator, not\n');
    fprintf('                              the model. Judge this one on bias.)\n');
end
if C.ratio > 2 || C.ratio < 0.5
    fprintf('    ratio      twin / measured = %.4g\n', C.ratio);
end
end


function [tag, level] = classify(C)
%CLASSIFY  One place that decides what counts as agreement.
%
%   The verdict table and the paragraph under it used to apply their own
%   thresholds, and disagreed: a -99.9 % error printed as DIVERGES in the
%   table while the prose said every stage agreed, because the prose tested
%   for > 100 %. Both now come through here.
if abs(C.pct_error) < 5
    tag = 'AGREES';   level = 0;
elseif abs(C.pct_error) < 25
    tag = 'close';    level = 1;
else
    tag = 'DIVERGES'; level = 2;
end
end


function verdictRow(label, C)
tag = classify(C);
fprintf('  stage %-24s %-10s %+9.1f %%\n', label, tag, C.pct_error);
end


function w = nseWord(nse)
if nse > 0.75
    w = '(good)';
elseif nse > 0.5
    w = '(acceptable)';
elseif nse > 0
    w = '(poor, but better than the mean)';
else
    w = '(worse than just predicting the mean)';
end
end


%% ========================================================================
%  Plots
%  ========================================================================

function makePlots(obs, S1, S2, file)
%MAKEPLOTS  Measured against predicted, one panel per signal.
%
%   S1 is the stage 1 prediction, driven by rainfall. S2 is the stage 3-4
%   prediction, driven by the measured flow. Each panel uses the one that
%   actually predicted it.
try
    f = figure('Name', 'WATAPAC: measured vs digital twin', ...
               'Position', [100 100 900 700]);

    panels = {
      'Flow rate (L/min)  - predicted from rainfall', obs.flow_lpm,  S1.Q_lpm
      'Bus voltage (V)    - predicted from flow',     obs.voltage_v, S2.v_bus
      'Current (A)        - predicted from flow',     obs.current_a, S2.current_a
      'Power (W)          - predicted from flow',     obs.power_w,   S2.dc_w };

    for i = 1:size(panels,1)
        subplot(2, 2, i);
        o = panels{i,2}(:)'; s = panels{i,3}(:)';
        if isscalar(s); s = repmat(s, size(o)); end
        x = 1:numel(o);
        plot(x, o, 'o-', 'LineWidth', 1.4, 'MarkerSize', 6); hold on;
        plot(x, s, 's--', 'LineWidth', 1.4, 'MarkerSize', 6);
        grid on;
        title(panels{i,1}, 'FontSize', 9);
        xlabel('sample');
        legend('measured', 'twin', 'Location', 'best');
        % A twin that is orders of magnitude out needs a log axis or the
        % smaller trace is a flat line on the floor.
        if max([o s]) / max(min([o s]), eps) > 50
            set(gca, 'YScale', 'log');
            ylabel('log scale');
        end
        hold off;
    end

    if ~isempty(file)
        print(f, file, '-dpng', '-r120');
        fprintf('\n  figure saved: %s\n', file);
    end
catch err
    fprintf('\n  (plot skipped: %s)\n', err.message);
end
end


%% ========================================================================
function opts = parseOptions(args)
opts = struct('Params', [], 'Log', '', 'Url', '', 'Hours', 24, ...
              'Plot', true, 'PlotFile', '');
if mod(numel(args), 2) ~= 0
    error('watapac_compare:badArgs', 'Options must be name-value pairs.');
end
for i = 1:2:numel(args)
    name = char(args{i});
    if ~isfield(opts, name)
        error('watapac_compare:badArgs', 'Unknown option "%s". Valid: %s.', ...
            name, strjoin(fieldnames(opts)', ', '));
    end
    opts.(name) = args{i+1};
end
if isempty(opts.Params); opts.Params = watapac_twin_params(); end
if ~isempty(opts.Log) && ~isempty(opts.Url)
    error('watapac_compare:badArgs', 'Give either Log or Url, not both.');
end
end

function s = stddev(x)
if numel(x) < 2; s = 0; return; end
s = sqrt(sum((x - mean(x)).^2) / (numel(x) - 1));
end

function section(t)
fprintf('\n');
rule('-');
fprintf(' %s\n', t);
rule('-');
end

function rule(c)
fprintf('%s\n', repmat(c, 1, 74));
end
