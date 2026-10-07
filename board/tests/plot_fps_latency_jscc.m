function plot_fps_latency_jscc(csv_file, out_prefix)
% DeepJSCC-Q only: frame rate and end-to-end latency over time (left) with their PDF (right), one figure each,
% style of the GLOBECOM 2025 FPGA DeepJSCC paper (Fig. 8). Thin lines instead of one marker per frame (18000 frames).
%   plot_fps_latency_jscc('meas/lat_video_10min_jscc2_jscc_0dB.csv', 'meas/jscc_10min')
%   -> <out_prefix>_fps.{pdf,emf,png}, <out_prefix>_latency.{pdf,emf,png}
T = readtable(csv_file);
c = [0 0.4470 0.7410];
one(T.t_min, T.fps, 'FPS', [20 70], [out_prefix '_fps'], c);
one(T.t_min, T.lat_ms, 'Latency [ms]', [40 110], [out_prefix '_latency'], c);
end

function one(t, y, ylab, yl, out, c)
ok = ~isnan(y); t = t(ok); y = y(ok);
fig = figure('Color', 'w', 'Units', 'centimeters', 'Position', [2 2 17 5.6]);
tl = tiledlayout(fig, 1, 6, 'TileSpacing', 'compact', 'Padding', 'compact');
ax1 = nexttile(tl, [1 5]);
plot(ax1, t, y, '-', 'Color', c, 'LineWidth', 0.3);
grid(ax1, 'on'); box(ax1, 'on'); style(ax1);
xlim(ax1, [0, ceil(max(t))]); ylim(ax1, yl);
xlabel(ax1, 'Elapsed time [min]'); ylabel(ax1, ylab);
ax2 = nexttile(tl);
[f, x] = ksdensity(y, linspace(yl(1), yl(2), 600));
plot(ax2, f, x, 'Color', c, 'LineWidth', 1.3);
grid(ax2, 'on'); box(ax2, 'on'); style(ax2);
ylim(ax2, yl); xlim(ax2, [0, 1.1 * max(f)]); ax2.YTickLabel = []; xlabel(ax2, 'PDF');
fprintf('%s: median %.2f, mean %.2f, p1 %.2f, p99 %.2f, min %.2f, max %.2f (n %d)\n', ylab, median(y), mean(y), ...
        prctile(y, 1), prctile(y, 99), min(y), max(y), numel(y));
exportgraphics(fig, [out '.pdf'], 'ContentType', 'vector');
exportgraphics(fig, [out '.emf'], 'ContentType', 'vector');
exportgraphics(fig, [out '.png'], 'Resolution', 300);
fprintf('written %s.{pdf,emf,png}\n', out);
close(fig);
end

function style(ax)
ax.FontName = 'Times New Roman'; ax.FontSize = 11; ax.LineWidth = 0.8; ax.GridAlpha = 0.25;
end
