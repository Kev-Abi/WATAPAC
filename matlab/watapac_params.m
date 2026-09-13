function p = watapac_params(varargin)
%WATAPAC_PARAMS  Single source of truth for the WATAPAC turbine geometry.
%
%   Every dimension the 3-D model uses lives here and nowhere else, so the
%   Simscape build script, any future CAD export, and the web viewer model
%   can never drift apart. Change a number here and rebuild.
%
%   ALL LENGTHS ARE IN METRES. ALL ANGLES ARE IN DEGREES.
%
%   The defaults are carried over from the first draft builder script and are
%   NOT measured from the prototype. Replace them with real numbers before
%   using this model for anything but a picture.
%
%   Usage:
%       p = watapac_params();
%       disp(p.hub_radius_m)
%
%   Fields can be overridden as name-value pairs, which re-runs validation on
%   the result. Use this to try a variant without editing the file:
%       p = watapac_params('n_blades', 12, 'blade_pitch_deg', 30);

% --- Cascade layout -------------------------------------------------------
p.n_stages          = 2;        % turbines in series along the flow
p.stage_spacing_m   = 0.25;     % centre-to-centre spacing between stages

% Which way the channel runs. A Revolute Joint always turns about its own Z
% axis, so this decides the machine's whole architecture:
%
%   'X'  stages side by side along the channel, each on its own vertical
%        shaft -- a cross-flow / paddle cascade
%   'Z'  stages stacked on one common horizontal axis -- an axial turbine
%
% UNVERIFIED: 'X' is a guess from the word "cascade" and the drainage-channel
% use case. Check it against the prototype before trusting the model.
p.stage_offset_axis = 'X';

% --- Hub ------------------------------------------------------------------
p.hub_radius_m      = 0.045;
p.hub_length_m      = 0.080;

% --- Shaft ----------------------------------------------------------------
p.shaft_radius_m    = 0.012;
p.shaft_length_m    = 0.180;

% --- Blades ---------------------------------------------------------------
p.n_blades          = 8;        % per stage
p.blade_length_m    = 0.130;    % radial, root to tip
p.blade_width_m     = 0.035;    % along the flow
p.blade_thick_m     = 0.008;
p.blade_pitch_deg   = 20;       % twist about the blade's own radial axis
p.stage_clock_deg   = 22.5;     % stage 2 rotated relative to stage 1, so the
                                % blades do not shadow each other

% --- Appearance (cosmetic only; a failure to apply these never stops a build)
p.color_hub         = [0.30 0.32 0.35];
p.color_shaft       = [0.55 0.57 0.60];
p.color_blade       = [0.10 0.45 0.70];

p = applyOverrides(p, varargin);

% --- Derived --------------------------------------------------------------
% Computed AFTER the overrides, so overriding hub_radius_m or n_blades cannot
% leave a stale derived value behind.
%
% A blade is placed by its centre, so it has to sit half its own length
% beyond the hub surface or it would be buried in the hub.
p.blade_radial_offset_m = p.hub_radius_m + p.blade_length_m / 2;
p.blade_angle_step_deg  = 360 / p.n_blades;

validate(p);
end


function p = applyOverrides(p, args)
%APPLYOVERRIDES  Name-value pairs on top of the defaults.
%
%   Only existing fields can be set. A typo'd field name is a mistake worth
%   catching here rather than silently ignoring, which would leave the caller
%   thinking a value took effect when it did not.
if mod(numel(args), 2) ~= 0
    error('watapac_params:badArgs', 'Overrides must be name-value pairs.');
end
for i = 1:2:numel(args)
    name = args{i};
    if ~ischar(name) && ~isstring(name)
        error('watapac_params:badArgs', 'Override name #%d is not text.', (i+1)/2);
    end
    name = char(name);
    if ~isfield(p, name)
        error('watapac_params:noSuchField', ...
            'No parameter named "%s". Valid names:\n  %s', ...
            name, strjoin(fieldnames(p)', ', '));
    end
    p.(name) = args{i+1};
end
end


function validate(p)
%VALIDATE  Catch impossible geometry here rather than as a Simscape error.
assert(p.n_stages >= 1 && mod(p.n_stages,1) == 0, ...
    'watapac_params: n_stages must be a positive integer.');
assert(p.n_blades >= 2 && mod(p.n_blades,1) == 0, ...
    'watapac_params: n_blades must be an integer >= 2.');

names = {'stage_spacing_m','hub_radius_m','hub_length_m','shaft_radius_m', ...
         'shaft_length_m','blade_length_m','blade_width_m','blade_thick_m'};
for i = 1:numel(names)
    v = p.(names{i});
    assert(isscalar(v) && isnumeric(v) && v > 0, ...
        'watapac_params: %s must be a positive scalar.', names{i});
end

assert(ischar(p.stage_offset_axis) && isscalar(p.stage_offset_axis) && ...
    any(upper(p.stage_offset_axis) == 'XYZ'), ...
    'watapac_params: stage_offset_axis must be the character ''X'', ''Y'' or ''Z''.');

assert(p.shaft_radius_m < p.hub_radius_m, ...
    ['watapac_params: shaft_radius_m (%.4f) must be smaller than ' ...
     'hub_radius_m (%.4f) — the shaft passes through the hub.'], ...
    p.shaft_radius_m, p.hub_radius_m);

% Blades are placed around the hub circumference; if they are wider than the
% arc available to each one they will intersect, which Simscape will render
% happily and which is nonetheless wrong.
arc = 2 * pi * p.hub_radius_m / p.n_blades;
if p.blade_width_m > arc
    warning('watapac:bladeOverlap', ...
        ['%d blades of width %.3f m do not fit around a hub of radius ' ...
         '%.3f m (%.3f m of arc each). They will intersect.'], ...
        p.n_blades, p.blade_width_m, p.hub_radius_m, arc);
end

if p.n_stages > 1 && p.stage_spacing_m < p.blade_width_m
    warning('watapac:stageOverlap', ...
        'stage_spacing_m (%.3f) is less than blade_width_m (%.3f); stages will collide.', ...
        p.stage_spacing_m, p.blade_width_m);
end
end
