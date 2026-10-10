function mdl = watapac_build_turbine_3d(varargin)
%WATAPAC_BUILD_TURBINE_3D  Build the WATAPAC cascade turbine in Simscape Multibody.
%
%   Produces a Mechanics Explorer model of the turbine's PHYSICAL GEOMETRY.
%   It does not model hydraulics, torque, or the generator — that coupling is
%   the next step, and is deliberately absent rather than faked.
%
%   RUN watapac_check_env FIRST. It reports what your MATLAB release calls the
%   blocks and parameters this script needs.
%
%   Usage
%       watapac_build_turbine_3d
%       watapac_build_turbine_3d('Open', false, 'Save', false)
%       p = watapac_params(); p.n_blades = 12;
%       watapac_build_turbine_3d('Params', p)
%
%   Name-value options
%       'Params'    struct from watapac_params (default: watapac_params())
%       'ModelName' char (default 'WATAPAC_3D_Simscape_Turbine')
%       'Open'      logical, open the diagram when done (default true)
%       'Save'      logical, write the .slx (default true)
%
%   HOW THIS DIFFERS FROM THE FIRST DRAFT (matlab/legacy/)
%   The draft added Solid blocks and expected them to appear at the right
%   place. They will not: in Simscape Multibody a Solid sits exactly at the
%   frame it is connected to, and a block's Position argument moves it on the
%   2-D canvas only. Every offset and rotation has to be a Rigid Transform
%   block in the frame network. That is most of what this script builds.
%
%   WHY THE PARAMETER NAMES ARE RESOLVED AT RUNTIME
%   Simscape Multibody dialog parameter names differ between releases. Rather
%   than hardcode one release's spelling and fail with a cryptic error, every
%   set_param goes through setAny(), which tries the known spellings and — if
%   none match — reports what the block does expose. Cosmetic settings warn
%   and continue; structural ones stop the build.

%% ---- Options -----------------------------------------------------------
opts = parseOptions(varargin);
p    = opts.Params;
mdl  = opts.ModelName;

paramLog('reset');

fprintf('\n=== WATAPAC 3-D turbine builder ===\n');
fprintf('  model   : %s\n', mdl);
fprintf('  stages  : %d, %d blades each (%d solids total)\n', ...
    p.n_stages, p.n_blades, p.n_stages * (p.n_blades + 2));
fprintf('  spacing : %.3f m along %s\n\n', p.stage_spacing_m, p.stage_offset_axis);

%% ---- Resolve the library ------------------------------------------------
L = resolveLibraries();

%% ---- Fresh model --------------------------------------------------------
if bdIsLoaded(mdl)
    close_system(mdl, 0);
end
existing = which([mdl '.slx']);
if ~isempty(existing)
    delete(existing);
    fprintf('  removed previous %s\n', existing);
end
new_system(mdl);

% If anything below throws, do not leave a half-built model loaded.
guard = onCleanup(@() closeIfIncomplete(mdl));

%% ---- World, solver, mechanism configuration -----------------------------
world = addBlk(mdl, L.WorldFrame, 'World Frame', [40 300 100 340]);
mech  = addBlk(mdl, L.MechanismConfiguration, 'Mechanism Configuration', [40 380 170 420]);
solv  = addBlk(mdl, L.SolverConfiguration, 'Solver Configuration', [40 460 170 500]);

% Both configuration blocks attach anywhere on the frame network; the world
% frame is the one node guaranteed to exist.
connect(mdl, world, 1, mech, 1);
connect(mdl, world, 1, solv, 1);

%% ---- Stages -------------------------------------------------------------
rowHeight = 120 + p.n_blades * 60;

for s = 1:p.n_stages
    y0  = 40 + (s-1) * rowHeight;
    tag = sprintf('S%d', s);

    % --- position this stage along the channel ---
    offset = zeros(1,3);
    offset(axisIndex(p.stage_offset_axis)) = (s-1) * p.stage_spacing_m;
    rtStage = addBlk(mdl, L.RigidTransform, sprintf('%s Stage Offset', tag), ...
        [200 y0+80 280 y0+140]);
    setTranslation(rtStage, offset);
    connect(mdl, world, 1, rtStage, 1);

    % --- the shaft's degree of freedom ---
    % A Revolute Joint rotates about the Z axis of its base frame, so every
    % rotating part downstream of it shares that axis.
    joint = addBlk(mdl, L.RevoluteJoint, sprintf('%s Shaft Joint', tag), ...
        [340 y0+80 420 y0+140]);
    connect(mdl, rtStage, 2, joint, 1);

    % --- hub and shaft, both coaxial with the joint, so no transform ---
    hub = addBlk(mdl, L.cylinderBlock, sprintf('%s Hub', tag), [520 y0+20 620 y0+80]);
    setSolidCylinder(hub, p.hub_radius_m, p.hub_length_m, L.cylinderIsShaped);
    setSolidColor(hub, p.color_hub);
    connect(mdl, joint, 2, hub, 1);

    shaft = addBlk(mdl, L.cylinderBlock, sprintf('%s Shaft', tag), [520 y0+100 620 y0+160]);
    setSolidCylinder(shaft, p.shaft_radius_m, p.shaft_length_m, L.cylinderIsShaped);
    setSolidColor(shaft, p.color_shaft);
    connect(mdl, joint, 2, shaft, 1);

    % --- blades ---
    % Three transforms per blade, each doing exactly one thing. A single
    % combined transform would depend on whether Simscape applies its
    % translation before or after its rotation; splitting them means the
    % result is the same either way.
    for k = 1:p.n_blades
        angle = (k-1) * p.blade_angle_step_deg + (s-1) * p.stage_clock_deg;
        yb    = y0 + 200 + (k-1) * 60;
        bt    = sprintf('%s B%02d', tag, k);

        % 1. swing round the hub
        rtRot = addBlk(mdl, L.RigidTransform, [bt ' Clock'], [520 yb 600 yb+40]);
        setRotation(rtRot, 'Z', angle);
        connect(mdl, joint, 2, rtRot, 1);

        % 2. push out past the hub surface, along the now-radial local X
        rtOff = addBlk(mdl, L.RigidTransform, [bt ' Radius'], [640 yb 720 yb+40]);
        setTranslation(rtOff, [p.blade_radial_offset_m 0 0]);
        connect(mdl, rtRot, 2, rtOff, 1);

        % 3. twist about that radial axis
        rtPitch = addBlk(mdl, L.RigidTransform, [bt ' Pitch'], [760 yb 840 yb+40]);
        setRotation(rtPitch, 'X', p.blade_pitch_deg);
        connect(mdl, rtOff, 2, rtPitch, 1);

        blade = addBlk(mdl, L.brickBlock, [bt ' Blade'], [880 yb 980 yb+40]);
        % X radial (length), Y tangential (thickness), Z along the shaft (width)
        setSolidBrick(blade, [p.blade_length_m p.blade_thick_m p.blade_width_m], L.brickIsShaped);
        setSolidColor(blade, p.color_blade);
        connect(mdl, rtPitch, 2, blade, 1);
    end

    fprintf('  stage %d built: hub, shaft, %d blades\n', s, p.n_blades);
end

%% ---- Tidy, update, save -------------------------------------------------
try
    Simulink.BlockDiagram.arrangeSystem(mdl);
catch
    % Auto-layout is cosmetic and not on every release.
end

fprintf('\n  compiling...\n');
try
    set_param(mdl, 'SimulationCommand', 'update');
    fprintf('  compiled clean.\n');
catch err
    fprintf(2, '\n  MODEL DID NOT COMPILE\n    %s\n', err.message);
    fprintf(2, '  The diagram is built and left open so you can inspect it.\n');
    fprintf(2, '  Send this message plus the watapac_check_env output.\n\n');
end

if opts.Save
    target = fullfile(fileparts(mfilename('fullpath')), [mdl '.slx']);
    save_system(mdl, target);
    fprintf('  saved: %s\n', target);
end

if opts.Open
    open_system(mdl);
end

clear guard;   % build finished; do not close the model

paramLog('report');

fprintf('\n  Next: run the model, then Simulation > Mechanics Explorer.\n');
fprintf('  The shafts are free to rotate but nothing drives them yet —\n');
fprintf('  hydraulic torque and the generator are still to be coupled.\n\n');
end


%% ========================================================================
%  Library resolution
%  ========================================================================

function L = resolveLibraries()
%RESOLVELIBRARIES  Find each block, whatever sublibrary this release files it under.
libs = {'sm_lib', 'nesl_utility', 'simulink'};
for i = 1:numel(libs)
    try
        load_system(libs{i});
    catch
        % simulink is always present; a missing sm_lib is caught below.
    end
end

% Candidate paths first (fast, and they document the expected layout), then a
% search by block name as the fallback that survives a library reorganisation.
spec = { ...
  'WorldFrame',              'World Frame', ...
      {'sm_lib/Frames and Transforms/World Frame', 'sm_lib/Environment/World Frame'}; ...
  'RigidTransform',          'Rigid Transform', ...
      {'sm_lib/Frames and Transforms/Rigid Transform'}; ...
  'Solid',                   'Solid', ...
      {'sm_lib/Body Elements/Solid'}; ...
  'SolidCylinder',           'Cylindrical Solid', ...
      {'sm_lib/Body Elements/Cylindrical Solid', ...
       'sm_lib/Body Elements/Solids/Cylindrical Solid'}; ...
  'SolidBrick',              'Brick Solid', ...
      {'sm_lib/Body Elements/Brick Solid', ...
       'sm_lib/Body Elements/Solids/Brick Solid'}; ...
  'RevoluteJoint',           'Revolute Joint', ...
      {'sm_lib/Joints/Revolute Joint'}; ...
  'MechanismConfiguration',  'Mechanism Configuration', ...
      {'sm_lib/Utilities/Mechanism Configuration', 'sm_lib/Environment/Mechanism Configuration'}; ...
  'SolverConfiguration',     'Solver Configuration', ...
      {'nesl_utility/Solver Configuration', 'simscape/Utilities/Solver Configuration'} };

L = struct();
for i = 1:size(spec,1)
    key        = spec{i,1};
    blockName  = spec{i,2};
    candidates = spec{i,3};

    found = '';
    for j = 1:numel(candidates)
        if blockExists(candidates{j})
            found = candidates{j};
            break;
        end
    end

    if isempty(found)
        found = searchByName(blockName, libs);
    end

    % The solid blocks are alternatives to each other, not all required:
    % R2026a dropped the generic Solid in favour of shape-specific blocks,
    % while older releases have only the generic one. Resolve what exists
    % and decide afterwards whether enough of it is there.
    optional = any(strcmp(key, {'Solid', 'SolidCylinder', 'SolidBrick'}));

    if isempty(found) && ~optional
        error('watapac:blockNotFound', ...
            ['Cannot find the "%s" block.\n' ...
             'Tried: %s\n' ...
             'and searched %s by name.\n' ...
             'Run watapac_check_env to see what is installed.'], ...
            blockName, strjoin(candidates, ', '), strjoin(libs, ', '));
    end

    L.(key) = found;
    if ~isempty(found)
        fprintf('  block  : %-24s -> %s\n', blockName, found);
    end
end

% Pick which solid blocks to use, preferring the shape-specific ones.
L.cylinderBlock = firstNonEmpty({L.SolidCylinder, L.Solid});
L.brickBlock    = firstNonEmpty({L.SolidBrick,    L.Solid});
L.cylinderIsShaped = ~isempty(L.SolidCylinder);
L.brickIsShaped    = ~isempty(L.SolidBrick);

if isempty(L.cylinderBlock) || isempty(L.brickBlock)
    error('watapac:noSolidBlock', ...
        ['No usable solid block found in sm_lib.\n' ...
         'Looked for "Solid", "Cylindrical Solid" and "Brick Solid".\n' ...
         'Run watapac_check_env -- it lists every block whose name\n' ...
         'contains "Solid" on this release -- and send the output.']);
end
fprintf('  solids : cylinder -> %s\n', L.cylinderBlock);
fprintf('           brick    -> %s\n', L.brickBlock);
fprintf('\n');
end


function out = firstNonEmpty(items)
out = '';
for i = 1:numel(items)
    if ~isempty(items{i}); out = items{i}; return; end
end
end


function tf = blockExists(path)
tf = false;
try
    tf = ~isempty(find_system(fileparts(path), 'LookUnderMasks', 'all', ...
        'FollowLinks', 'on', 'SearchDepth', 1, 'Name', pathLeaf(path)));
catch
end
end


function name = pathLeaf(path)
parts = strsplit(path, '/');
name  = parts{end};
end


function path = searchByName(blockName, libs)
path = '';
for i = 1:numel(libs)
    try
        hits = find_system(libs{i}, 'LookUnderMasks', 'all', ...
            'FollowLinks', 'on', 'Name', blockName);
    catch
        continue;
    end
    if ischar(hits); hits = {hits}; end
    % strfind rather than contains(): contains() is R2016b+.
    hits = hits(~cellfun(@isempty, strfind(hits, '/')));
    if ~isempty(hits)
        path = hits{1};
        return;
    end
end
end


%% ========================================================================
%  Block and line helpers
%  ========================================================================

function blk = addBlk(mdl, libPath, name, pos)
blk = [mdl '/' name];
add_block(libPath, blk, 'Position', pos);
end


function connect(mdl, srcBlk, srcPortIdx, dstBlk, dstPortIdx)
%CONNECT  Join two physical ports, addressed by position rather than by name.
%
%   Physical connection ports are called LConn1/RConn1/... depending on which
%   side of the block they are drawn on, which varies with the block and can
%   change if a block is mirrored. Reading the identifier out of
%   PortConnectivity avoids guessing. Ports are in dialog order, so for a
%   two-port block index 1 is the base frame B and index 2 the follower F.
srcPort = portId(srcBlk, srcPortIdx);
dstPort = portId(dstBlk, dstPortIdx);
try
    add_line(mdl, [shortName(srcBlk) '/' srcPort], ...
                  [shortName(dstBlk) '/' dstPort], 'autorouting', 'on');
catch err
    error('watapac:connectFailed', ...
        ['Could not connect %s/%s -> %s/%s\n' ...
         '  %s ports: %s\n' ...
         '  %s ports: %s\n' ...
         '  underlying error: %s'], ...
        shortName(srcBlk), srcPort, shortName(dstBlk), dstPort, ...
        shortName(srcBlk), strjoin(allPortIds(srcBlk), ', '), ...
        shortName(dstBlk), strjoin(allPortIds(dstBlk), ', '), ...
        err.message);
end
end


function id = portId(blk, idx)
ids = allPortIds(blk);
if idx > numel(ids)
    error('watapac:noSuchPort', ...
        'Block %s has %d ports; asked for #%d. Ports: %s', ...
        shortName(blk), numel(ids), idx, strjoin(ids, ', '));
end
id = ids{idx};
end


function ids = allPortIds(blk)
ids = {};
try
    pc = get_param(blk, 'PortConnectivity');
    for i = 1:numel(pc)
        ids{end+1} = pc(i).Type; %#ok<AGROW>
    end
catch
end
end


function name = shortName(blk)
%SHORTNAME  Strip the model prefix; add_line wants a path relative to it.
idx = strfind(blk, '/');
if isempty(idx)
    name = blk;
else
    name = blk(idx(1)+1:end);
end
end


%% ========================================================================
%  Parameter setting, with runtime name resolution
%  ========================================================================

function setSolidCylinder(blk, radius, len, isShaped)
%SETSOLIDCYLINDER  A Cylindrical Solid already knows its shape; a generic
%   Solid has to be told. Only the generic one takes the shape parameter.
if ~isShaped
    setAnyValue(blk, firstParamPresent(blk, {'GeometryShape','ShapeType','Shape'}), ...
        {'Cylinder'}, 'cylinder shape', true);
end
setAny(blk, {'CylinderRadius','Radius'}, num2str(radius, '%.6g'), 'cylinder radius', true);
setAny(blk, {'CylinderLength','Length'}, num2str(len, '%.6g'), 'cylinder length', true);
end


function setSolidBrick(blk, dims, isShaped)
if ~isShaped
    setAnyValue(blk, firstParamPresent(blk, {'GeometryShape','ShapeType','Shape'}), ...
        {'Brick'}, 'brick shape', true);
end
setAny(blk, {'BrickDimensions','Dimensions'}, mat2str(dims), 'brick dimensions', true);
end


function name = firstParamPresent(blk, candidates)
%FIRSTPARAMPRESENT  The first of CANDIDATES this block actually has.
avail = paramNames(blk);
for i = 1:numel(candidates)
    if any(strcmp(avail, candidates{i})); name = candidates{i}; return; end
end
error('watapac:paramNotFound', ...
    ['%s has none of: %s\n  block exposes: %s\n' ...
     'Run watapac_check_env and send its output.'], ...
    shortName(blk), strjoin(candidates, ', '), strjoin(avail, ', '));
end


function setSolidColor(blk, rgb)
% Cosmetic only. A release that spells these differently should not stop a build.
setAny(blk, {'GraphicType','VisualType'}, 'Simple', 'graphic type', false);
setAny(blk, {'SimpleVisualShapeColor','Color','VisualColor'}, mat2str(rgb), 'colour', false);
end


function setRotation(blk, axis, degrees)
%SETROTATION  Rotation only; translation explicitly disabled.
%
%   Parameter names confirmed against R2026a by watapac_check_env. The
%   rotation axis is RotationStandardAxis, not RotationAxis -- worth noting,
%   because RotationAxis does not exist and the guess failed silently in the
%   sense that nothing matched and the build stopped.
%
%   The enum VALUES are release-dependent too. Confirmed on R2026a:
%     RotationMethod       None | AlignedAxes | StandardAxis | ArbitraryAxis
%                          | RotationSequence | RotationMatrix | Quaternion
%     RotationStandardAxis +X | -X | +Y | -Y | +Z | -Z
%     TranslationMethod    None | Cartesian | StandardAxis | Cylindrical
%   So 'StandardAxis' with no space, and '+Z' with the sign. Older releases
%   spelled some of these differently, hence the fallbacks.
setAnyValue(blk, 'RotationMethod', {'StandardAxis','Standard Axis'}, ...
    'rotation method', true);
setAny(blk, {'RotationStandardAxis','RotationAxis','StandardAxis'}, ...
    ['+' axis], 'rotation axis', true);
setAny(blk, {'RotationAngle','AngleR'}, num2str(degrees, '%.6g'), 'rotation angle', true);
setAny(blk, {'RotationAngleUnits','AngleUnits'}, 'deg', 'angle units', false);
setAnyValue(blk, 'TranslationMethod', {'None'}, 'translation method (none)', false);
end


function setTranslation(blk, xyz)
%SETTRANSLATION  Translation only; rotation explicitly disabled.
setAnyValue(blk, 'RotationMethod', {'None'}, 'rotation method (none)', false);
setAnyValue(blk, 'TranslationMethod', {'Cartesian'}, 'translation method', true);
setAny(blk, {'TranslationCartesianOffset','CartesianOffset'}, ...
    mat2str(xyz), 'cartesian offset', true);
setAny(blk, {'TranslationCartesianOffsetUnits','CartesianOffsetUnits'}, ...
    'm', 'offset units', false);
end


function ok = setAnyValue(blk, name, candidateValues, what, required)
%SETANYVALUE  One parameter name, several possible spellings of its VALUE.
%
%   The mirror image of setAny: there the name was uncertain, here the name
%   is known and the accepted enum string is not.
ok = false;
if ~any(strcmp(paramNames(blk), name))
    if required
        error('watapac:paramNotFound', ...
            ['%s has no parameter "%s".\n  block exposes: %s\n' ...
             'Run watapac_check_env and send its output.'], ...
            shortName(blk), name, strjoin(paramNames(blk), ', '));
    end
    return;
end

lastErr = '';
for i = 1:numel(candidateValues)
    try
        set_param(blk, name, candidateValues{i});
        paramLog('add', [what ' value (' blockKind(blk) ')'], ...
            [name ' = ' candidateValues{i}]);
        ok = true;
        return;
    catch err
        lastErr = err.message;
    end
end

allowed = '<unknown>';
try
    op = get_param(blk, 'ObjectParameters');
    if isfield(op, name) && isfield(op.(name), 'Enum')
        allowed = strjoin(op.(name).Enum(:)', ' | ');
    end
catch
end
msg = sprintf(['could not set %s on %s\n' ...
    '  parameter    : %s\n  tried values : %s\n' ...
    '  accepts      : %s\n  last error   : %s\n'], ...
    what, shortName(blk), name, strjoin(candidateValues, ', '), allowed, lastErr);
if required
    error('watapac:badEnumValue', '%s', msg);
else
    warning('watapac:badEnumValue', '%s', msg);
end
end


function ok = setAny(blk, candidates, value, what, required)
%SETANY  set_param under whichever of CANDIDATES this release actually has.
ok    = false;
avail = paramNames(blk);
lastErr = '';

for i = 1:numel(candidates)
    name = candidates{i};
    if ~any(strcmp(avail, name))
        continue;
    end
    try
        set_param(blk, name, value);
        paramLog('add', [what ' (' blockKind(blk) ')'], name);
        ok = true;
        return;
    catch err
        % The name exists but rejected the value — usually a wrong enum
        % spelling, e.g. 'Standard Axis' vs 'StandardAxis'.
        lastErr = err.message;
    end
end

msg = sprintf(['could not set %s on %s\n' ...
    '  tried names   : %s\n' ...
    '  value         : %s\n' ...
    '  block exposes : %s\n'], ...
    what, shortName(blk), strjoin(candidates, ', '), toChar(value), ...
    strjoin(avail, ', '));
if ~isempty(lastErr)
    msg = sprintf('%s  last error    : %s\n', msg, lastErr);
end
msg = sprintf('%s  Run watapac_check_env and send its output.\n', msg);

if required
    error('watapac:paramNotFound', '%s', msg);
else
    warning('watapac:paramNotFound', '%s', msg);
end
end


function kind = blockKind(blk)
%BLOCKKIND  Which library block this instance came from, for the log summary.
kind = '?';
try
    ref = get_param(blk, 'ReferenceBlock');
    if ~isempty(ref)
        kind = pathLeaf(ref);
    end
catch
end
end


function names = paramNames(blk)
%PARAMNAMES  Names this block accepts, preferring the dialog list.
names = {};
try
    dp = get_param(blk, 'DialogParameters');
    if isstruct(dp)
        names = fieldnames(dp);
    end
catch
end
if isempty(names)
    try
        op = get_param(blk, 'ObjectParameters');
        if isstruct(op)
            names = fieldnames(op);
        end
    catch
    end
end
end


function out = paramLog(action, key, value)
%PARAMLOG  Record which parameter spelling worked, and report it once.
%
%   The summary is the point: it is the list to hardcode once the release in
%   use is known, and the first thing to look at if a rebuild behaves oddly.
persistent M
if isempty(M)
    M = containers.Map('KeyType', 'char', 'ValueType', 'char');
end
out = [];

switch action
    case 'reset'
        M = containers.Map('KeyType', 'char', 'ValueType', 'char');
    case 'add'
        M(key) = value;
    case 'report'
        if M.Count == 0
            return;
        end
        fprintf('\n  --- parameter names this release used ---\n');
        k = keys(M);
        for i = 1:numel(k)
            fprintf('    %-34s -> %s\n', k{i}, M(k{i}));
        end
end
end


%% ========================================================================
%  Small utilities
%  ========================================================================

function opts = parseOptions(args)
opts = struct('Params', [], 'ModelName', 'WATAPAC_3D_Simscape_Turbine', ...
              'Open', true, 'Save', true);
if mod(numel(args), 2) ~= 0
    error('watapac:badArgs', 'Options must be name-value pairs.');
end
for i = 1:2:numel(args)
    name = args{i};
    if ~isfield(opts, name)
        error('watapac:badArgs', 'Unknown option "%s". Valid: %s.', ...
            toChar(name), strjoin(fieldnames(opts)', ', '));
    end
    opts.(name) = args{i+1};
end
if isempty(opts.Params)
    opts.Params = watapac_params();
end
if ~isfield(opts.Params, 'stage_offset_axis')
    opts.Params.stage_offset_axis = 'X';
end
end


function idx = axisIndex(axisChar)
switch upper(axisChar)
    case 'X', idx = 1;
    case 'Y', idx = 2;
    case 'Z', idx = 3;
    otherwise
        error('watapac:badAxis', ...
            'stage_offset_axis must be ''X'', ''Y'' or ''Z'', got "%s".', ...
            toChar(axisChar));
end
end


function s = toChar(v)
if ischar(v)
    s = v;
elseif isstring(v)
    s = char(v);
elseif isnumeric(v) || islogical(v)
    s = mat2str(v);
else
    s = ['<' class(v) '>'];
end
end


function closeIfIncomplete(mdl)
try
    if bdIsLoaded(mdl)
        close_system(mdl, 0);
        fprintf(2, '  build failed — discarded the partial model.\n');
    end
catch
end
end
