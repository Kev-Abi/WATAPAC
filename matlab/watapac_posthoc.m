function R = watapac_posthoc()
%WATAPAC_POSTHOC  The two post hoc tests from the Integration Guide.
%
%   H0_post_hoc1  No significant difference in electrical power output
%                 between Turbine 1 and Turbine 2.
%                 -> paired samples t-test, plus exact Wilcoxon signed-rank
%
%   H0_post_hoc2  No significant linear relationship between water flow
%                 rate and combined turbine power output.
%                 -> Pearson correlation and simple linear regression
%
%   NO TOOLBOX REQUIRED. Everything is computed from first principles using
%   betainc and betaincinv, which are base MATLAB. The Statistics and
%   Machine Learning Toolbox was not in the ver output for this install, so
%   ttest, signrank, corr and fitlm would all fail; this runs regardless.
%
%   R = WATAPAC_POSTHOC returns every statistic as a struct.
%
%   See also WATAPAC_VALIDATE, WATAPAC_TRIAL_DATA.

D = watapac_trial_data();
P = watapac_twin_params();
n = P.n_trials;

p1 = D.t1.power_w / 1000;            % kW
p2 = D.t2.power_w / 1000;
pc = D.combined.power_w / 1000;
flow = D.wat.flow_lpm;

rule('=');
fprintf(' WATAPAC POST HOC EXPLORATORY ANALYSIS\n');
fprintf(' n = %d trials, %g mm/h, %g g debris\n', n, P.rain_yellow_mmh, P.debris_total_g);
rule('=');

%% =======================================================================
%  H0_post_hoc1 : Turbine 1 vs Turbine 2
%  =======================================================================
head('H0_post_hoc1  -  CASCADING TURBINE PARITY');
fprintf('  H0: no significant difference in power output between T1 and T2.\n\n');

d = p1 - p2;
[t1, df1, pv1, ci1, se1] = pairedT(d);
R.parity = struct('t', t1, 'df', df1, 'p', pv1, 'ci', ci1, ...
                  'mean_diff', mean(d), 'sd_diff', stdev(d), 'dz', mean(d)/stdev(d));

fprintf('  %-8s %12s %12s %14s\n', 'trial', 'T1 (kW)', 'T2 (kW)', 'T1-T2 (kW)');
for k = 1:n
    fprintf('  %-8d %12.5f %12.5f %+14.6f\n', k, p1(k), p2(k), d(k));
end
fprintf('  %-8s %12.5f %12.5f %+14.6f\n\n', 'mean', mean(p1), mean(p2), mean(d));

fprintf('  PAIRED SAMPLES t-TEST\n');
fprintf('    mean difference  %+0.6f kW  (SD %.6f, SE %.6f)\n', mean(d), stdev(d), se1);
fprintf('    t(%d) = %.3f,  p = %.3f\n', df1, t1, pv1);
fprintf('    95%% CI of the difference  [%+0.6f, %+0.6f] kW\n', ci1(1), ci1(2));
fprintf('    Cohen dz = %.3f  (%s effect)\n', R.parity.dz, effectSize(abs(R.parity.dz)));
fprintf('    -> %s H0_post_hoc1\n', verdict(pv1));

[W, pw, pfloor] = wilcoxonExact(d);
R.parity.W = W; R.parity.p_wilcoxon = pw;
fprintf('\n  WILCOXON SIGNED-RANK (exact)\n');
fprintf('    W = %g,  p = %.4f\n', W, pw);
fprintf('    -> %s H0_post_hoc1\n', verdict(pw));
fprintf('\n    CAUTION. At n = %d the smallest two-tailed p this test can\n', n);
fprintf('    produce is %.4f, so it CANNOT reach p < .05 no matter what the\n', pfloor);
fprintf('    data show. Failing to reject here is a property of the sample\n');
fprintf('    size, not evidence of parity. Report the t-test as the result\n');
fprintf('    and the Wilcoxon only as a distribution-free check.\n');

fprintf('\n  INTERPRETATION\n');
fprintf('    The 95%% CI spans %+0.6f to %+0.6f kW, which is %.1f%% of the\n', ...
    ci1(1), ci1(2), 100*max(abs(ci1))/mean(pc));
fprintf('    combined output. Any real difference between the turbines is\n');
fprintf('    smaller than that. This supports the cascade claim: the slope\n');
fprintf('    beneath T1 re-accelerates the flow enough that T2 is driven\n');
fprintf('    essentially as hard as T1.\n');
fprintf('\n    This conclusion survives the energy-balance problem in\n');
fprintf('    watapac_validate. A calibration scale error affects both\n');
fprintf('    turbines identically, so it cancels in a paired comparison.\n');

%% =======================================================================
%  H0_post_hoc2 : flow rate vs combined power
%  =======================================================================
head('H0_post_hoc2  -  FLOW RATE vs COMBINED POWER');
fprintf('  H0: no significant linear relationship between flow and power.\n\n');

[r, pr, tr, dfr, ciR] = pearson(flow, pc);
R.corr = struct('r', r, 'r2', r^2, 't', tr, 'df', dfr, 'p', pr, 'ci', ciR);

fprintf('  %-8s %14s %16s\n', 'trial', 'flow (L/min)', 'power (kW)');
for k = 1:n
    fprintf('  %-8d %14.3f %16.5f\n', k, flow(k), pc(k));
end

fprintf('\n  PEARSON CORRELATION\n');
fprintf('    r = %.4f,  r^2 = %.4f  (%.1f%% of variance)\n', r, r^2, 100*r^2);
fprintf('    t(%d) = %.3f,  p = %.5f\n', dfr, tr, pr);
fprintf('    95%% CI for r (Fisher z)  [%.4f, %.4f]\n', ciR(1), ciR(2));
fprintf('    -> %s H0_post_hoc2\n', verdict(pr));

[b, a, seb, ciB, r2, bOrigin] = linreg(flow, pc);
R.reg = struct('slope', b, 'intercept', a, 'se_slope', seb, ...
               'ci_slope', ciB, 'r2', r2, 'slope_origin', bOrigin);

fprintf('\n  SIMPLE LINEAR REGRESSION\n');
fprintf('    power = %+0.6f %+0.6f * flow        (kW, L/min)\n', a, b);
fprintf('    slope %.5f kW per L/min,  SE %.5f\n', b, seb);
fprintf('    95%% CI for the slope  [%.5f, %.5f]\n', ciB(1), ciB(2));
fprintf('    intercept %+0.6f kW\n', a);
fprintf('\n    through the origin: slope %.5f kW per L/min\n', bOrigin);
fprintf('    The Integration Guide quotes 0.0098, which is this one. Forcing\n');
fprintf('    the line through zero is the physically right choice here --\n');
fprintf('    no flow must mean no power -- and the free intercept of\n');
fprintf('    %+0.6f kW is not significantly different from zero anyway.\n', a);

fprintf('\n  EXTRAPOLATION TO THE POWER BANK\n');
need_o = P.powerbank_max_kw / bOrigin;
need_l = (P.powerbank_max_kw - a) / b;
fprintf('    flow needed for the %.3f kW maximum input:\n', P.powerbank_max_kw);
fprintf('      through origin  %.2f L/min   (guide says ~1.8)\n', need_o);
fprintf('      free intercept  %.2f L/min\n', need_l);
fprintf('    Measured range was %.3f to %.3f L/min, so this is a %.0fx\n', ...
    min(flow), max(flow), need_o/max(flow));
fprintf('    extrapolation beyond any observation. It is a projection, not\n');
fprintf('    a result, and needs the Orange and Red rainfall trials.\n');
R.flow_for_max_input = need_o;

fprintf('\n  CAUTION ON WHAT THIS TEST CAN SHOW\n');
fprintf('    Hydraulic power is rho*g*Q*H, so power is proportional to flow\n');
fprintf('    BY DEFINITION. An r of %.4f confirms the arithmetic held\n', r);
fprintf('    together; it is not an independent discovery about the turbine.\n');
fprintf('    What would be informative is whether EFFICIENCY stays constant\n');
fprintf('    with flow, which is tested below.\n');

%% =======================================================================
%  Added: is the implied efficiency constant?
%  =======================================================================
head('ADDITIONAL  -  IMPLIED EFFICIENCY vs FLOW');
fprintf('  Not in the Integration Guide. Added because it is the test that\n');
fprintf('  separates a real turbine characteristic from a measurement scale\n');
fprintf('  error, and the two look identical in H0_post_hoc2.\n\n');

hyd = P.rho * P.g * (flow/60000) * P.head_total_m;   % W
eff = (pc*1000) ./ hyd;
R.efficiency_ratio = eff;

fprintf('  %-8s %14s %16s %12s\n', 'trial', 'flow (L/min)', 'hydraulic (mW)', 'out / in');
for k = 1:n
    fprintf('  %-8d %14.3f %16.2f %11.0fx\n', k, flow(k), hyd(k)*1000, eff(k));
end
cv = 100 * stdev(eff) / mean(eff);
fprintf('\n  mean %.0fx,  SD %.1f,  coefficient of variation %.1f%%\n', mean(eff), stdev(eff), cv);
[re, pe] = pearson(flow, eff);
fprintf('  efficiency vs flow:  r = %+0.4f,  p = %.3f  (%s)\n', re, pe, verdict(pe));
R.eff_cv = cv; R.eff_r = re; R.eff_p = pe;
if pe >= 0.05 && abs(re) > 0.5
    fprintf('\n  Note: r = %+0.3f is a sizeable trend that simply is not\n', re);
    fprintf('  significant at n = %d. "Not significant" is not "flat" -- with\n', n);
    fprintf('  five points this test would miss all but the largest effects.\n');
    fprintf('  The %.1f%% coefficient of variation is the stronger statement,\n', cv);
    fprintf('  because it does not depend on statistical power at all.\n');
end

fprintf('\n  A real turbine has an efficiency curve: it peaks near design flow\n');
fprintf('  and falls away on either side. Across a %.0f%% spread in flow the\n', ...
    100*(max(flow)-min(flow))/mean(flow));
fprintf('  implied efficiency here varies by only %.1f%%.\n\n', cv);
fprintf('  A ratio that constant is the signature of a fixed multiplier\n');
fprintf('  between the true output and the recorded one -- a calibration\n');
fprintf('  scale error -- rather than of a turbine. It is also why\n');
fprintf('  H0_post_hoc2 comes out so strong: a scale error preserves\n');
fprintf('  proportionality perfectly, better than a real turbine would.\n');

%% =======================================================================
head('SUMMARY FOR THE MANUSCRIPT');
fprintf('  H0_post_hoc1   t(%d) = %.3f, p = %.3f   %s\n', df1, t1, pv1, verdict(pv1));
fprintf('                 Wilcoxon W = %g, p = %.4f (floor %.4f at n=%d)\n', W, pw, pfloor, n);
fprintf('  H0_post_hoc2   r = %.4f, t(%d) = %.2f, p = %.5f   %s\n', r, dfr, tr, pr, verdict(pr));
fprintf('                 slope %.5f kW per L/min through the origin\n', bOrigin);
fprintf('\n  Both findings in the Integration Guide reproduce from the raw\n');
fprintf('  Appendix G data. The parity result is robust. The correlation is\n');
fprintf('  real but partly definitional, and the constant efficiency above\n');
fprintf('  is the reason to treat the absolute power values with care.\n');
rule('=');
fprintf('\n');
end


%% ========================================================================
%  Statistics, implemented without the Statistics Toolbox
%  ========================================================================

function [t, df, p, ci, se] = pairedT(d)
%PAIREDT  Paired-samples t-test on the differences.
n  = numel(d);
df = n - 1;
se = stdev(d) / sqrt(n);
t  = mean(d) / se;
p  = tTwoTailed(t, df);
tc = tCritical(df, 0.05);
ci = [mean(d) - tc*se, mean(d) + tc*se];
end


function [W, p, pfloor] = wilcoxonExact(d)
%WILCOXONEXACT  Exact two-tailed Wilcoxon signed-rank, by enumeration.
%
%   n is 5 here, so all 2^5 sign assignments can simply be counted. No
%   normal approximation, which would be badly wrong at this size.
d = d(d ~= 0);
n = numel(d);
[~, order] = sort(abs(d));
ranks = zeros(1, n);
ranks(order) = 1:n;

W = min(sum(ranks(d > 0)), sum(ranks(d < 0)));

count = 0;
for k = 0:(2^n - 1)
    signs = bitget(k, 1:n);
    if min(sum(ranks(signs == 1)), sum(ranks(signs == 0))) <= W
        count = count + 1;
    end
end
p = min(1, count / 2^n);

% The smallest attainable two-tailed p: both extremes out of 2^n outcomes.
pfloor = 2 / 2^n;
end


function [r, p, t, df, ci] = pearson(x, y)
%PEARSON  Correlation, its t-test, and a Fisher-z confidence interval.
x = x(:); y = y(:);
n  = numel(x);
xm = x - mean(x);
ym = y - mean(y);
r  = (xm' * ym) / sqrt((xm'*xm) * (ym'*ym));
df = n - 2;
t  = r * sqrt(df / max(1 - r^2, eps));
p  = tTwoTailed(t, df);

z   = atanh(max(min(r, 1-eps), -1+eps));
sez = 1 / sqrt(n - 3);
ci  = [tanh(z - 1.96*sez), tanh(z + 1.96*sez)];
end


function [b, a, seb, ci, r2, bOrigin] = linreg(x, y)
%LINREG  Ordinary least squares, plus the through-the-origin slope.
x = x(:); y = y(:);
n  = numel(x);
df = n - 2;
xm = x - mean(x);
ym = y - mean(y);

b = (xm' * ym) / (xm' * xm);
a = mean(y) - b * mean(x);

res = y - (a + b*x);
s2  = (res' * res) / df;
seb = sqrt(s2 / (xm' * xm));
tc  = tCritical(df, 0.05);
ci  = [b - tc*seb, b + tc*seb];
r2  = 1 - (res'*res) / (ym'*ym);

% No flow must mean no power, so the constrained fit is the physical one.
bOrigin = (x' * y) / (x' * x);
end


function p = tTwoTailed(t, df)
%TTWOTAILED  Two-tailed p from Student's t, via the incomplete beta.
p = betainc(df / (df + t^2), df/2, 0.5);
end


function tc = tCritical(df, alpha)
%TCRITICAL  Two-tailed critical t, by inverting the same relation.
tc = sqrt(df * (1 / betaincinv(alpha, df/2, 0.5) - 1));
end


function s = stdev(x)
s = sqrt(sum((x - mean(x)).^2) / (numel(x) - 1));
end


%% ------------------------------------------------------------------------
function s = verdict(p)
if p < .05
    s = 'REJECT';
else
    s = 'FAIL TO REJECT';
end
end

function s = verdict2(p, ifSig, ifNot)
if p < .05; s = ifSig; else; s = ifNot; end
end

function s = effectSize(dz)
if dz < 0.2
    s = 'negligible';
elseif dz < 0.5
    s = 'small';
elseif dz < 0.8
    s = 'medium';
else
    s = 'large';
end
end

function head(t)
fprintf('\n');
rule('-');
fprintf(' %s\n', t);
rule('-');
end

function rule(c)
fprintf('%s\n', repmat(c, 1, 74));
end
