function watapac_check_env()
%WATAPAC_CHECK_ENV  Report what this MATLAB install actually calls things.
%
%   RUN THIS FIRST, BEFORE watapac_build_turbine_3d.
%
%   Simscape Multibody block library paths and dialog parameter names have
%   moved between releases, and no amount of reading documentation is a
%   substitute for asking your own installation. This script asks it, then
%   prints the answer.
%
%   It writes nothing and saves nothing. It creates one scratch model in
%   memory, interrogates the blocks, and closes it.
%
%   Copy the whole output and keep it. If the builder fails, the output of
%   this script is what identifies which name it should have used.

fprintf('\n===============================================================\n');
fprintf(' WATAPAC environment check\n');
fprintf(' %s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS'));
fprintf('===============================================================\n\n');

%% 1. Release and toolboxes
fprintf('--- MATLAB release -------------------------------------------\n');
fprintf('  version : %s\n', version);
fprintf('  release : %s\n\n', version('-release'));

fprintf('--- Required toolboxes ---------------------------------------\n');
% Neither ver() nor license() has a stable key for Simscape Multibody: the
% toolbox directory has been 'sm' and 'slmultibody', and the licence feature
% is still the legacy 'SimMechanics' on some releases. Checking one spelling
% produced a FALSE NEGATIVE on R2026a -- it reported the toolbox missing
% while sm_lib loaded and every block was found.
%
% So try every known spelling, and treat "the library actually loads" as the
% answer that counts, because that is the thing the builder depends on.
needed = { ...
    'Simulink',           {'simulink'},                  {'Simulink'},            'simulink'; ...
    'Simscape',           {'simscape'},                  {'Simscape'},            'nesl_utility'; ...
    'Simscape Multibody', {'sm','slmultibody','smlink'}, {'Simscape_Multibody','SimMechanics'}, 'sm_lib'};
allPresent = true;
for i = 1:size(needed,1)
    label   = needed{i,1};
    verKeys = needed{i,2};
    features= needed{i,3};
    libName = needed{i,4};

    installed = false;
    for k = 1:numel(verKeys)
        try
            if ~isempty(ver(verKeys{k})); installed = true; break; end
        catch
        end
    end

    licensed = false;
    for k = 1:numel(features)
        try
            if license('test', features{k}); licensed = true; break; end
        catch
        end
    end

    % The decisive test: does the block library load?
    libLoads = false;
    try
        load_system(libName);
        libLoads = true;
    catch
    end

    ok = libLoads;
    fprintf('  %-22s ver=%-5s licence=%-5s library=%-5s %s\n', label, ...
        mat2str(installed), mat2str(licensed), mat2str(libLoads), tick(ok));
    allPresent = allPresent && ok;
    continue;
end
fprintf('\n');
fprintf('  "library" is the one that matters: it is what the builder uses.\n');
if ~allPresent
    fprintf('  >> A block library failed to load. The 3-D builder needs all three.\n');
    fprintf('     (The Simulink digital twin needs only base Simulink.)\n');
end
fprintf('\n');

%% 2. Where the blocks actually live
fprintf('--- Library block paths --------------------------------------\n');
libs = {'sm_lib', 'nesl_utility', 'simulink'};
for i = 1:numel(libs)
    try
        load_system(libs{i});
        fprintf('  loaded library: %s\n', libs{i});
    catch err
        fprintf('  FAILED to load library %s (%s)\n', libs{i}, err.identifier);
    end
end
fprintf('\n');

wanted = {'World Frame', 'Rigid Transform', 'Solid', 'Revolute Joint', ...
          'Mechanism Configuration', 'Solver Configuration'};
found = struct();
for i = 1:numel(wanted)
    name = wanted{i};
    paths = locateBlock(name, libs);
    key = fieldKey(name);
    found.(key) = paths;
    if isempty(paths)
        fprintf('  %-26s NOT FOUND in any loaded library\n', name);
    else
        for j = 1:numel(paths)
            fprintf('  %-26s %s\n', name, paths{j});
        end
    end
end
fprintf('\n');

%% 3. Dialog parameter names, straight from the blocks
fprintf('--- Block parameter names ------------------------------------\n');
fprintf('  (these are the names set_param must use on THIS release)\n\n');

mdl = 'watapac_probe_scratch';
if bdIsLoaded(mdl); close_system(mdl, 0); end
new_system(mdl);
cleanup = onCleanup(@() closeQuietly(mdl));

probe = {'Solid', 'Rigid Transform', 'Revolute Joint', 'World Frame', ...
         'Mechanism Configuration'};
for i = 1:numel(probe)
    name = probe{i};
    key = fieldKey(name);
    paths = found.(key);
    if isempty(paths)
        fprintf('  [%s] skipped — block not found\n\n', name);
        continue;
    end

    dest = [mdl '/probe_' key];
    try
        add_block(paths{1}, dest);
    catch err
        fprintf('  [%s] add_block FAILED: %s\n\n', name, err.message);
        continue;
    end

    fprintf('  [%s]  from %s\n', name, paths{1});
    printParams(dest);
    printPorts(dest);
    fprintf('\n');
end

%% 4. The solid family
% R2026a did not find a block called exactly "Solid". Recent Simscape
% Multibody splits the generic Solid into shape-specific blocks, so list
% everything in the library whose name ends in "Solid" and find out what
% this release actually offers.
fprintf('--- Blocks whose name contains "Solid" -----------------------\n');
solidPaths = locateBlock('.*Solid.*', {'sm_lib'}, true);
if isempty(solidPaths)
    fprintf('  none found\n\n');
else
    for i = 1:numel(solidPaths)
        fprintf('  %s\n', solidPaths{i});
    end
    fprintf('\n');
    % Probe the first cylinder-ish and brick-ish one for its parameters.
    for want = {'Cylind', 'Brick'}
        hit = '';
        for i = 1:numel(solidPaths)
            if ~isempty(strfind(solidPaths{i}, want{1})); hit = solidPaths{i}; break; end
        end
        if isempty(hit); continue; end
        dest = [mdl '/probe_' regexprep(pathLeafName(hit), '[^A-Za-z0-9]', '')];
        try
            add_block(hit, dest);
            fprintf('  [%s]\n', hit);
            printParams(dest);
            printPorts(dest);
            fprintf('\n');
        catch err
            fprintf('  [%s] add_block FAILED: %s\n\n', hit, err.message);
        end
    end
end

%% 5. Allowed values for the enumerated parameters
% Knowing a parameter is called RotationMethod is only half of it; the
% builder also has to pass a value it accepts. These are the lists.
fprintf('--- Allowed values for enumerated parameters -----------------\n');
enumWanted = {
  'RigidTransform',  {'RotationMethod','RotationStandardAxis','TranslationMethod', ...
                      'RotationAngleUnits','TranslationCartesianOffsetUnits'} };
for i = 1:size(enumWanted,1)
    blk = [mdl '/probe_' enumWanted{i,1}];
    if ~blockPresent(blk); continue; end
    for j = 1:numel(enumWanted{i,2})
        printEnum(blk, enumWanted{i,2}{j});
    end
end
fprintf('\n');

fprintf('===============================================================\n');
fprintf(' Done. Send this whole output along if the builder errors.\n');
fprintf('===============================================================\n\n');
end


%% ------------------------------------------------------------------------
function printEnum(blk, param)
%PRINTENUM  List the values an enumerated block parameter will accept.
try
    op = get_param(blk, 'ObjectParameters');
    if ~isfield(op, param)
        fprintf('  %-34s (not on this block)\n', param);
        return;
    end
    info = op.(param);
    if isfield(info, 'Enum') && ~isempty(info.Enum)
        fprintf('  %-34s %s\n', param, strjoin(info.Enum(:)', ' | '));
    else
        fprintf('  %-34s (free text, currently "%s")\n', param, get_param(blk, param));
    end
catch err
    fprintf('  %-34s unreadable: %s\n', param, err.message);
end
end


function tf = blockPresent(blk)
tf = false;
try
    tf = ~isempty(find_system(get_param(blk,'Parent'), 'SearchDepth', 1, ...
        'Name', pathLeafName(blk)));
catch
end
end


function name = pathLeafName(path)
parts = strsplit(path, '/');
name = parts{end};
end


%% ------------------------------------------------------------------------
function paths = locateBlock(name, libs, useRegexp)
%LOCATEBLOCK  Search the loaded libraries for a block by name.
%
%   R2026a warns that find_system skips inactive Variant Subsystem choices
%   unless asked otherwise, and that is exactly how a block can go missing
%   from a search while sitting in the library browser. Ask for all variants
%   where the release supports it, and fall back quietly where it does not.
if nargin < 3; useRegexp = false; end
paths = {};
for i = 1:numel(libs)
    args = {'LookUnderMasks', 'all', 'FollowLinks', 'on'};
    if useRegexp; args = [args {'Regexp', 'on'}]; end %#ok<AGROW>
    hits = {};
    try
        hits = find_system(libs{i}, args{:}, ...
            'MatchFilter', @Simulink.match.allVariants, 'Name', name);
    catch
        try
            hits = find_system(libs{i}, args{:}, 'Name', name);
        catch
            continue;
        end
    end
    if ischar(hits); hits = {hits}; end
    paths = [paths; hits(:)]; %#ok<AGROW>
end
% A library root can match its own name; keep only real sublibrary paths.
% strfind rather than contains(): contains() is R2016b+, and this script has
% to be able to run on whatever release it is handed in order to diagnose it.
paths = paths(~cellfun(@isempty, strfind(paths, '/')));
end


function printParams(blk)
%PRINTPARAMS  List the dialog parameters a block exposes, with current values.
names = {};
try
    dp = get_param(blk, 'DialogParameters');
    if isstruct(dp); names = fieldnames(dp); end
catch
end
if isempty(names)
    try
        op = get_param(blk, 'ObjectParameters');
        if isstruct(op); names = fieldnames(op); end
    catch
    end
end

if isempty(names)
    fprintf('    (no parameter list available — probe with get_param manually)\n');
    return;
end

% Simulink puts ~60 generic parameters on every block. Those are noise here;
% what matters is the block-specific ones.
generic = {'Position','Orientation','ForegroundColor','BackgroundColor', ...
    'DropShadow','NamePlacement','FontName','FontSize','FontWeight', ...
    'FontAngle','ShowName','BlockRotation','BlockMirror','Tag','Description', ...
    'Priority','AttributesFormatString','Selected','HiliteAncestors', ...
    'RequirementInfo','Opaque','MaskType','MaskDescription','MaskHelp', ...
    'MaskPromptString','MaskStyleString','MaskVariables','MaskValueString', ...
    'MaskDisplay','MaskIconFrame','MaskIconOpaque','MaskIconRotate', ...
    'MaskIconUnits','MaskSelfModifiable','MaskCallbackString','MaskEnableString', ...
    'MaskVisibilityString','MaskTunableValueString','MaskCallbacks', ...
    'MaskEnables','MaskVisibilities','MaskTunableValues','MaskNames', ...
    'MaskInitialization','MaskWSVariables','LinkStatus','StaticLinkStatus', ...
    'AncestorBlock','ReferenceBlock','SourceBlock','SourceType','Handle', ...
    'Name','Parent','Type','Path','LineHandles','PortHandles', ...
    'PortConnectivity','DialogParameters','ObjectParameters','CopyFcn', ...
    'DeleteFcn','InitFcn','LoadFcn','ModelCloseFcn','NameChangeFcn', ...
    'OpenFcn','ParentCloseFcn','PreSaveFcn','PostSaveFcn','StartFcn', ...
    'StopFcn','UndoDeleteFcn','ErrorFcn','CloseFcn','MoveFcn','PreCopyFcn', ...
    'PreDeleteFcn','ContinueFcn','IOType','RTWData','UserData', ...
    'UserDataPersistent','SimViewingDevice','Commented','SafetyPrecautions'};
specific = setdiff(names, generic, 'stable');

fprintf('    parameters (%d block-specific of %d total):\n', ...
    numel(specific), numel(names));
for i = 1:numel(specific)
    val = '<unreadable>';
    try
        v = get_param(blk, specific{i});
        if ischar(v)
            val = v;
        elseif isnumeric(v) || islogical(v)
            val = mat2str(v);
        else
            val = ['<' class(v) '>'];
        end
    catch
    end
    if numel(val) > 46; val = [val(1:43) '...']; end
    fprintf('      %-32s = %s\n', specific{i}, val);
end
end


function printPorts(blk)
%PRINTPORTS  Print the port identifiers add_line has to use.
try
    pc = get_param(blk, 'PortConnectivity');
catch
    fprintf('    (ports unavailable)\n');
    return;
end
if isempty(pc)
    fprintf('    ports: none\n');
    return;
end
ids = cell(1, numel(pc));
for i = 1:numel(pc)
    ids{i} = pc(i).Type;
end
fprintf('    ports for add_line: %s\n', strjoin(ids, ', '));
end


function key = fieldKey(name)
%FIELDKEY  Block name -> struct field name, without matlab.lang.makeValidName.
key = regexprep(name, '[^A-Za-z0-9]', '');
end


function s = tick(ok)
if ok; s = 'OK'; else; s = '<-- MISSING'; end
end


function closeQuietly(mdl)
try
    if bdIsLoaded(mdl); close_system(mdl, 0); end
catch
end
end
