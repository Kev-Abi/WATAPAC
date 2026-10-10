function D = watapac_trial_data()
%WATAPAC_TRIAL_DATA  The measured results, transcribed from the manuscript.
%
%   Appendix G, Tables G1-G3. Five trials of 16 min 40 s each, simulated
%   Yellow rainfall (15 mm/h), 25 g debris load.
%
%   Everything else in this folder is derived; this is the only file holding
%   numbers that came off the bench. Derived columns (flow rate, power,
%   energy, filtration efficiency) are RECOMPUTED here from the raw volume,
%   mass, current and voltage rather than copied from Tables 1-7, so that
%   running this file also checks the published tables for arithmetic
%   errors. watapac_validate prints the comparison.

D.trial_seconds = 16*60 + 40;
D.debris_load_g = 25.0;

% --- Table G1: conventional drainage model ------------------------------
D.conv.volume_l   = [3.508 5.708 3.921 4.508 5.163];
D.conv.debris_g   = [24.2  23.7  24.4  23.9  23.3 ];

% --- Table G1: WATAPAC prototype ----------------------------------------
D.wat.volume_l    = [4.242 5.650 3.696 5.308 4.804];
D.wat.debris_g    = [24.3  23.9  24.6  24.2  24.7 ];

% --- Table G2: Turbine 1 -------------------------------------------------
D.t1.current_a    = [0.22  0.26  0.21  0.24  0.24 ];
D.t1.voltage_v    = [5.70  6.40  5.20  6.50  5.90 ];

% --- Table G3: Turbine 2 -------------------------------------------------
D.t2.current_a    = [0.23  0.25  0.21  0.24  0.23 ];
D.t2.voltage_v    = [5.60  6.50  5.30  6.60  6.10 ];

%% ---- Derived, recomputed from the raw values above ---------------------
hours = D.trial_seconds / 3600;
minutes = D.trial_seconds / 60;

D.conv.flow_lpm       = D.conv.volume_l / minutes;
D.wat.flow_lpm        = D.wat.volume_l  / minutes;
D.conv.filtration_pct = 100 * D.conv.debris_g / D.debris_load_g;
D.wat.filtration_pct  = 100 * D.wat.debris_g  / D.debris_load_g;

D.t1.power_w  = D.t1.current_a .* D.t1.voltage_v;
D.t2.power_w  = D.t2.current_a .* D.t2.voltage_v;
D.t1.energy_wh = D.t1.power_w * hours;
D.t2.energy_wh = D.t2.power_w * hours;

D.combined.power_w   = D.t1.power_w + D.t2.power_w;
D.combined.energy_wh = D.t1.energy_wh + D.t2.energy_wh;

% Charging time was computed per trial and then averaged in Table 7, which
% is not the same as dividing by the mean power (27.01 h vs 26.43 h). The
% per-trial form is kept because that is what the one-sample t-test used.
P = watapac_twin_params();
D.combined.charge_hours = (P.powerbank_kwh * 1000) ./ D.combined.power_w;

%% ---- Published values, for cross-checking ------------------------------
% Straight from Tables 1-7. watapac_validate compares these against the
% recomputed columns; any mismatch is a transcription or arithmetic error
% in the paper.
D.published.conv_flow_mean       = 0.274;
D.published.conv_filtration_mean = 95.6;
D.published.wat_flow_mean        = 0.284;
D.published.wat_filtration_mean  = 97.4;
D.published.t1_power_kw_mean     = 0.00140;
D.published.t2_power_kw_mean     = 0.00140;
D.published.combined_power_kw    = 0.00280;
D.published.combined_energy_kwh  = 0.000777;
D.published.charge_hours_mean    = 27.01;
D.published.charge_hours_sd      = 4.51;
D.published.t_statistic          = 11.4;
end
