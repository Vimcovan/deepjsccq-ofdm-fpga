function plot_seg_cdf(prefix, out)
% CDF of the three PL latency segments, style of Fig. 7 of the GLOBECOM 2025 FPGA DeepJSCC paper: one CDF per panel,
% dashed lines at the 0.5 % / 99.5 % delays (the few frames outside are time stamps of the PS polling loop that
% was preempted, e.g. one event 1.75 ms late, not PL delays), dotted minor grid, panels encoder / decoder / transmission.
% Input: <prefix>_3seg_{encoding,decoding,transmission}.csv of seg_latency.py (ms per frame).
%   plot_seg_cdf('meas/seg/segments', 'meas/seg/latency_3seg_cdf')
names = {'encoding', 'decoding', 'transmission'};
labels = {'(a) Encoder.', '(b) Decoder.', '(c) Transmission.'};
xlab = {'Processing delay [ms]', 'Processing delay [ms]', 'Transmission delay [ms]'};
fig = figure('Color', 'w', 'Units', 'centimeters', 'Position', [2 2 17 5.4]);
tl = tiledlayout(fig, 1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
for k = 1:3
    d = sort(readmatrix(sprintf('%s_3seg_%s.csv', prefix, names{k})));
    lo = prctile(d, 0.5); hi = prctile(d, 99.5); pad = 0.12 * (hi - lo);
    ax = nexttile(tl); hold(ax, 'on');
    xline(ax, lo, '--', 'Color', [0.35 0.35 0.35], 'LineWidth', 1.0);
    xline(ax, hi, '--', 'Color', [0.35 0.35 0.35], 'LineWidth', 1.0);
    stairs(ax, d, (1:numel(d))' / numel(d), 'Color', [0 0 1], 'LineWidth', 1.3);
    grid(ax, 'on'); grid(ax, 'minor'); box(ax, 'on');
    ax.MinorGridLineStyle = ':'; ax.GridLineStyle = ':'; ax.GridAlpha = 0.35; ax.MinorGridAlpha = 0.25;
    ax.FontName = 'Times New Roman'; ax.FontSize = 10.5; ax.LineWidth = 0.8;
    xlim(ax, [lo - pad, hi + pad]); ylim(ax, [0 1]); yticks(ax, [0 0.5 1]);
    xlabel(ax, {xlab{k}, labels{k}}); ylabel(ax, 'CDF');
    fprintf('%s: median %.3f ms, min %.3f, max %.3f, jitter (max-min) %.3f ms (n %d)\n', names{k}, median(d), lo, hi, ...
            hi - lo, numel(d));
end
exportgraphics(fig, [out '.pdf'], 'ContentType', 'vector');
exportgraphics(fig, [out '.emf'], 'ContentType', 'vector');
exportgraphics(fig, [out '.png'], 'Resolution', 300);
fprintf('written %s.{pdf,emf,png}\n', out);
close(fig);
end
