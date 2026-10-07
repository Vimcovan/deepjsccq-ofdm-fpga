function plot_psnr_snr(json_file, out_prefix)
% PSNR vs constellation SNR from a measure_link.py + analyze_const.py result (<run>_da.json), MATLAB style of the
% usual DeepJSCC papers. The y range covers the DeepJSCC degradation; the SSCC cliff leaves the plot at the bottom
% (below it nearly every frame fails and its PSNR means nothing).
%   plot_psnr_snr('meas/k0802_v3_da.json', 'meas/k0802_v3_psnr_snr')
%   -> <out_prefix>.pdf (vector), .emf (Word), .png (300 dpi)
if nargin < 2, out_prefix = regexprep(json_file, '_da\.json$', '_psnr_snr'); end
J = jsondecode(fileread(json_file));
R = J.results;
if ~iscell(R), R = num2cell(R); end

modes = {'jscc', 'sscc'};
names = {'DeepJSCC-Q', 'SSCC (JPEG + CC + 64QAM)'};
colors = {[0 0.4470 0.7410], [0.8500 0.3250 0.0980]};
markers = {'o', '>'};
src = '';

fig = figure('Color', 'w', 'Units', 'centimeters', 'Position', [2 2 15 11.5]);
ax = axes(fig); hold(ax, 'on');
for m = 1:2
    x = []; y = [];
    for k = 1:numel(R)
        r = R{k};
        if ~strcmp(r.mode, modes{m}) || isempty(r.snr_da_db) || isempty(r.psnr_shown), continue; end
        x(end + 1) = r.snr_da_db; y(end + 1) = r.psnr_shown; %#ok<AGROW>
        if isfield(r, 'src'), src = r.src; end
    end
    [x, i] = sort(x); y = y(i);
    plot(ax, x, y, ['-' markers{m}], 'Color', colors{m}, 'LineWidth', 1.5, 'MarkerSize', 6, ...
         'MarkerFaceColor', 'w', 'DisplayName', names{m});
end
grid(ax, 'on'); box(ax, 'on');
ax.FontName = 'Times New Roman'; ax.FontSize = 12; ax.LineWidth = 0.8;
ax.GridAlpha = 0.25; ax.Layer = 'top';
ylim(ax, [19 33.5]); yticks(ax, 19:2:33);
xl = xlim(ax); xlim(ax, [floor(xl(1)) - 0.5, ceil(xl(2)) + 0.5]);
xticks(ax, ceil(xl(1) / 3) * 3:3:floor(xl(2) / 3) * 3 + 3);
xlabel(ax, 'SNR (dB)'); ylabel(ax, 'PSNR (dB)');
title(ax, ['Over-the-air measurement, ' strrep(strrep(src, 'preset:div2k_', 'DIV2K '), '_', ' ')], ...
      'FontWeight', 'bold');
lg = legend(ax, 'Location', 'southeast'); lg.FontSize = 11; lg.Box = 'on';

exportgraphics(fig, [out_prefix '.pdf'], 'ContentType', 'vector');
exportgraphics(fig, [out_prefix '.emf'], 'ContentType', 'vector');
exportgraphics(fig, [out_prefix '.png'], 'Resolution', 300);
fprintf('written %s.{pdf,emf,png}\n', out_prefix);
close(fig);
end
