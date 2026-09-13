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
% ver() wants the toolbox directory name, which is not the display name --
% Simscape Multibody's is 'sm', not 'simscapemultibody'.
needed = { ...
    'Simulink',            'simulink', 'Simulink'; ...
    'Simscape',            'simscape', 'Simscape'; ...
    'Simscape Multibody',  'sm',       'Simscape_Multibody'};
allPresent = true;
for i = 1:size(needed,1)
    label   = needed{i,1};
    verKey  = needed{i,2};
    feature = needed{i,3};
    installed = false;
    try
        installed = ~isempty(ver(verKey));
    catch
    end
    licensed  = license('test', feature);
    ok = installed || licensed;
    allPresent = allPresent && ok;
    fprintf('  %-22s installed=%-5s licensed=%-5s %s\n', label, ...
        mat2str(installed), mat2str(licensed), tick(ok));
end
fprintf('\n');
if ~allPresent
    fprintf('  >> Missing a toolbox. The builder cannot run without all three.\n\n');
end

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

fprintf('===============================================================\n');
fprintf(' Done. Send this whole output along if the builder errors.\n');
fprintf('===============================================================\n\n');
end


%% ------------------------------------------------------------------------
function paths = locateBlock(name, libs)
%LOCATEBLOCK  Search the loaded libraries for a block by its exact name.
paths = {};
for i = 1:numel(libs)
    try
        hits = find_system(libs{i}, 'LookUnderMasks', 'all', ...
            'FollowLinks', 'on', 'Name', name);
    catch
        continue;
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
