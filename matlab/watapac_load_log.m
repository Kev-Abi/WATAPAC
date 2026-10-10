function T = watapac_load_log(varargin)
%WATAPAC_LOAD_LOG  Read logged WATAPAC telemetry into a table.
%
%   Two sources, same table out:
%
%     from the CSV files, when the logs are on this machine
%         T = watapac_load_log()
%         T = watapac_load_log('Dir', '/media/usb/logs')
%
%     from a running Pi over HTTP
%         T = watapac_load_log('Url', 'http://192.168.1.42:5000')
%
%   Options
%       'Dir'    folder of watapac-YYYY-MM-DD.csv files
%                (default: ../pi/logs relative to this file)
%       'Url'    base address of the Pi; /api/history is appended
%       'Hours'  how far back to read (default 24)
%
%   Missing measurements are NaN, never 0 — the server writes an empty cell
%   for a sensor it did not hear from, so an unplugged sensor cannot be
%   averaged in as a real zero.
%
%   Times come back as a UTC datetime in the 'timestamp' column.
%
%   Example
%       T = watapac_load_log('Hours', 72);
%       plot(T.timestamp, T.flowRate);
%       ylabel('L/min'); grid on
%
%       % energy against flow, ignoring gaps
%       ok = ~isnan(T.power) & ~isnan(T.flowRate);
%       scatter(T.flowRate(ok), T.power(ok));

opts = parseOptions(varargin);

if ~isempty(opts.Url)
    T = loadFromUrl(opts.Url, opts.Hours);
else
    T = loadFromDir(opts.Dir, opts.Hours);
end

if isempty(T)
    warning('watapac:noData', ...
        ['No rows found. Check that the server has been running with ' ...
         'WATAPAC_LOG_INTERVAL > 0, and that an Arduino was connected — ' ...
         'the log is only written while real readings are arriving.']);
    return;
end

T = sortrows(T, 'timestamp');
fprintf('  %d rows, %s to %s (UTC)\n', height(T), ...
    datestr(T.timestamp(1), 'yyyy-mm-dd HH:MM'), ...
    datestr(T.timestamp(end), 'yyyy-mm-dd HH:MM'));
end


%% ------------------------------------------------------------------------
function T = loadFromDir(logDir, hours)
if ~isfolder(logDir)
    error('watapac:noLogDir', ...
        ['Log directory not found: %s\n' ...
         'Either point at it with ''Dir'', or read from the Pi with ' ...
         '''Url'', ''http://<pi-ip>:5000''.'], logDir);
end

files = dir(fullfile(logDir, 'watapac-*.csv'));
if isempty(files)
    error('watapac:noLogFiles', 'No watapac-*.csv files in %s', logDir);
end

cutoff = (now - hours/24);   % local time, matched against file dates below
parts  = {};

for i = 1:numel(files)
    % Skip whole files that cannot overlap the window, so asking for the last
    % hour does not read a year of logs off an SD card.
    if files(i).datenum < cutoff
        continue;
    end
    path = fullfile(files(i).folder, files(i).name);
    try
        parts{end+1} = readtable(path); %#ok<AGROW>
    catch err
        warning('watapac:badLogFile', 'Skipped %s (%s)', files(i).name, err.message);
    end
end

if isempty(parts)
    T = table();
    return;
end

T = vertcat(parts{:});
T = normalise(T);
T = T(T.epoch >= (posixtime(datetime('now','TimeZone','UTC')) - hours*3600), :);
end


%% ------------------------------------------------------------------------
function T = loadFromUrl(baseUrl, hours)
baseUrl = regexprep(baseUrl, '/+$', '');
url = sprintf('%s/api/history?hours=%g&limit=2000', baseUrl, hours);

fprintf('  fetching %s\n', url);
try
    payload = webread(url, weboptions('Timeout', 30));
catch err
    error('watapac:fetchFailed', ...
        ['Could not read %s\n%s\n' ...
         'Check the Pi is running and reachable from this machine.'], ...
        url, err.message);
end

if ~isfield(payload, 'rows') || isempty(payload.rows)
    T = table();
    return;
end

% webread gives a struct array for uniform rows and a cell array otherwise.
rows = payload.rows;
if iscell(rows)
    rows = [rows{:}];
end

T = normalise(struct2table(rows));
end


%% ------------------------------------------------------------------------
function T = normalise(T)
%NORMALISE  One column layout regardless of which source produced the table.
%
%   The HTTP path arrives as text for every field because JSON rows come
%   straight from the CSV reader on the Pi; the file path arrives partly
%   typed already. Coercing both here means callers never have to care which
%   source they used.

numericCols = {'epoch','rain','waterCm','emergency','batteryPercent', ...
               'voltage','current','power','totalKwh','flowRate', ...
               'weatherTemp','weatherHumidity','weatherWind'};

for i = 1:numel(numericCols)
    name = numericCols{i};
    if ~ismember(name, T.Properties.VariableNames)
        continue;
    end
    col = T.(name);
    if isnumeric(col)
        continue;
    end
    if iscell(col) || isstring(col)
        % str2double turns '' into NaN, which is exactly the intent: an empty
        % cell in the log means "not measured", not "zero".
        T.(name) = str2double(string(col));
    end
end

if ismember('timestamp', T.Properties.VariableNames)
    ts = T.timestamp;
    if ~isdatetime(ts)
        T.timestamp = datetime(string(ts), 'InputFormat', ...
            'yyyy-MM-dd''T''HH:mm:ssXXX', 'TimeZone', 'UTC');
    end
end

textCols = {'waterLevel','floodRisk','weatherCondition'};
for i = 1:numel(textCols)
    name = textCols{i};
    if ismember(name, T.Properties.VariableNames)
        T.(name) = string(T.(name));
    end
end
end


%% ------------------------------------------------------------------------
function opts = parseOptions(args)
here = fileparts(mfilename('fullpath'));
opts = struct('Dir', fullfile(here, '..', 'pi', 'logs'), 'Url', '', 'Hours', 24);

if mod(numel(args), 2) ~= 0
    error('watapac:badArgs', 'Options must be name-value pairs.');
end
for i = 1:2:numel(args)
    name = args{i};
    if ~ischar(name) && ~isstring(name)
        error('watapac:badArgs', 'Option name #%d is not text.', (i+1)/2);
    end
    name = char(name);
    if ~isfield(opts, name)
        error('watapac:badArgs', 'Unknown option "%s". Valid: Dir, Url, Hours.', name);
    end
    opts.(name) = args{i+1};
end

if ~isnumeric(opts.Hours) || ~isscalar(opts.Hours) || opts.Hours <= 0
    error('watapac:badArgs', 'Hours must be a positive scalar.');
end
end
