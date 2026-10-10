%% WATAPAC 3D SIMSCAPE MULTIBODY TURBINE
% Builds a 3-D visual model of the WATAPAC cascade turbine assembly.
% Requires: Simulink + Simscape Multibody.
%
% The model is intended for Mechanics Explorer visualization.
% It represents the PHYSICAL GEOMETRY of the turbine, not the hydraulic
%/electrical equations.

clear; clc;

mdl = 'WATAPAC_3D_Simscape_Turbine';
if bdIsLoaded(mdl)
    close_system(mdl,0);
end
if exist([mdl '.slx'],'file')
    delete([mdl '.slx']);
end

new_system(mdl);
open_system(mdl);

%% Main environment
add_block('sm_lib/Environment/World Frame', [mdl '/World Frame'], ...
    'Position',[40 220 100 260]);

add_block('sm_lib/Environment/Mechanism Configuration', ...
    [mdl '/Mechanism Configuration'], ...
    'Position',[40 300 170 340]);

%% ---------------- TURBINE 1 ----------------
% Revolute joint = turbine shaft rotation
add_block('sm_lib/Joints/Revolute Joint', [mdl '/Turbine 1 Shaft'], ...
    'Position',[240 170 300 230]);

% Main hub
add_block('sm_lib/Body Elements/Solid', [mdl '/T1 Hub'], ...
    'Position',[360 130 450 190]);
set_param([mdl '/T1 Hub'], ...
    'GeometryShape','Cylinder', ...
    'CylinderRadius','0.045', ...
    'CylinderLength','0.08', ...
    'GraphicType','Simple');

% Shaft
add_block('sm_lib/Body Elements/Solid', [mdl '/T1 Shaft'], ...
    'Position',[360 215 450 275]);
set_param([mdl '/T1 Shaft'], ...
    'GeometryShape','Cylinder', ...
    'CylinderRadius','0.012', ...
    'CylinderLength','0.18', ...
    'GraphicType','Simple');

% 8 blades around hub
for k = 1:8
    ang = (k-1)*45;
    name = sprintf('T1 Blade %02d',k);
    add_block('sm_lib/Body Elements/Solid',[mdl '/' name], ...
        'Position',[500+(k-1)*5 80+(k-1)*5 590+(k-1)*5 130+(k-1)*5]);
    set_param([mdl '/' name], ...
        'GeometryShape','Brick', ...
        'BrickDimensions','[0.13 0.035 0.008]', ...
        'GraphicType','Simple');
end

%% ---------------- TURBINE 2 ----------------
add_block('sm_lib/Joints/Revolute Joint', [mdl '/Turbine 2 Shaft'], ...
    'Position',[240 430 300 490]);

add_block('sm_lib/Body Elements/Solid', [mdl '/T2 Hub'], ...
    'Position',[360 390 450 450]);
set_param([mdl '/T2 Hub'], ...
    'GeometryShape','Cylinder', ...
    'CylinderRadius','0.045', ...
    'CylinderLength','0.08', ...
    'GraphicType','Simple');

add_block('sm_lib/Body Elements/Solid', [mdl '/T2 Shaft'], ...
    'Position',[360 475 450 535]);
set_param([mdl '/T2 Shaft'], ...
    'GeometryShape','Cylinder', ...
    'CylinderRadius','0.012', ...
    'CylinderLength','0.18', ...
    'GraphicType','Simple');

for k = 1:8
    name = sprintf('T2 Blade %02d',k);
    add_block('sm_lib/Body Elements/Solid',[mdl '/' name], ...
        'Position',[500+(k-1)*5 340+(k-1)*5 590+(k-1)*5 390+(k-1)*5]);
    set_param([mdl '/' name], ...
        'GeometryShape','Brick', ...
        'BrickDimensions','[0.13 0.035 0.008]', ...
        'GraphicType','Simple');
end

%% ---------------- CONNECTIONS ----------------
% World -> turbine joints
add_line(mdl,'World Frame/R','Turbine 1 Shaft/B');
add_line(mdl,'World Frame/R','Turbine 2 Shaft/B');

% Joints -> hubs and shafts
add_line(mdl,'Turbine 1 Shaft/F','T1 Hub/R');
add_line(mdl,'Turbine 1 Shaft/F','T1 Shaft/R');

add_line(mdl,'Turbine 2 Shaft/F','T2 Hub/R');
add_line(mdl,'Turbine 2 Shaft/F','T2 Shaft/R');

%% Add simple explanatory annotations
add_block('simulink/Signal Routing/Goto',[mdl '/T1_Rotation'], ...
    'Position',[700 150 760 180]);
set_param([mdl '/T1_Rotation'],'GotoTag','Turbine1_RPM');

add_block('simulink/Signal Routing/Goto',[mdl '/T2_Rotation'], ...
    'Position',[700 450 760 480]);
set_param([mdl '/T2_Rotation'],'GotoTag','Turbine2_RPM');

add_block('simulink/Signal Routing/From',[mdl '/T1_RPM_Output'], ...
    'Position',[800 150 860 180]);
set_param([mdl '/T1_RPM_Output'],'GotoTag','Turbine1_RPM');

add_block('simulink/Signal Routing/From',[mdl '/T2_RPM_Output'], ...
    'Position',[800 450 860 480]);
set_param([mdl '/T2_RPM_Output'],'GotoTag','Turbine2_RPM');

%% Save
set_param(mdl,'SimulationCommand','update');
save_system(mdl,[mdl '.slx']);

disp(' ');
disp('WATAPAC 3-D Simscape Multibody model created.');
disp(['File: ' mdl '.slx']);
disp('Open Mechanics Explorer by running the simulation/update.');
disp(' ');
disp('IMPORTANT: This is a geometry/kinematics starter.');
disp('Hydraulic flow, turbine torque, generator, and measured sensor');
disp('data still need to be coupled to the physical model for the');
disp('research-grade Digital Twin.');
