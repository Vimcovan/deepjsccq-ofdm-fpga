# DeepJSCC-Q 模型：训练、量化导出、链路评估

模型按 Tung 等人 DeepJSCC-Q（IEEE JSAIT 2022）的结构实现：编码器 / 解码器各为 GDN / IGDN + 卷积，C = 32、
输出 16 通道，256×256×3 图像映射为 32768 个 64QAM 符号（每帧一幅图），发射端星座约束 + 熵（KL）正则。

| 文件 | 作用 |
|---|---|
| `deepjsccq_model.py` | 浮点模型（`paper_arch=True` 为论文结构；64QAM 发射端在训练中用直通估计，接收端输入连续均衡后的 I/Q） |
| `prepare_cache.py` | 训练图像解码一次存为 uint8 `.npy`（加速随机裁剪）；验证集存 256×256 中心裁剪 |
| `train_v2.py` | 训练（AWGN，训练 SNR 10 dB，KL 正则，ReduceLROnPlateau） |
| `ptq_int16.py`、`int_ref.py` | 训练后量化与整数参考模型（RTL 的逐比特参考，也用于 `sim/network`） |
| `export_fpga.py` | 导出 W8A12 整数模型：`params/*.mem`、`manifest.json`、golden 张量（供 RTL 生成与仿真） |
| `ofdm_channel.py`、`ofdm_eval.py`、`ofdm_eval_user.py` | 类 802.11a OFDM 链路模型下评估（PAPR、限幅、频率选择性信道、LTF 信道估计、ZF / MMSE） |
| `download_flickr2k.ps1` | 下载 Flickr2K 训练集 |

## 部署模型的来历（`data/model/checkpoint/`）

`best.pt`：第 1186 轮，验证集（DIV2K valid 100 张，256×256）PSNR 31.28 dB、Kodak 32.65 dB（AWGN 10 dB），
参数 387 288 个，平均发射功率 1.00，星座熵 6.00 bit。训练集 3450 张（DIV2K train 800 + Flickr2K 2650）。
训练分两段：前 200 轮（`args_epoch1-200.json`）后，以 `--plateau --plateau-patience 20` 续训到 1200 轮（`args.json`），
曲线见 `training.csv`、`summary.json`。

## 复现流程

```
# 1. 数据：DIV2K train/valid（https://data.vision.ee.ethz.ch/cvl/DIV2K/）、Flickr2K（download_flickr2k.ps1）
python prepare_cache.py --train-dirs <DIV2K_train_HR> <Flickr2K> --val-dir <DIV2K_valid_HR> --out data/cache
# 2. 训练（前 200 轮，再续训到 1200 轮）
python train_v2.py --cache data/cache --output-dir runs/long1200_paper_arch --paper-arch --kl-lambda 0.05 --epochs 200 --channels-last
python train_v2.py --cache data/cache --output-dir runs/long1200_paper_arch --paper-arch --kl-lambda 0.05 --epochs 1200 \
       --plateau --plateau-patience 20 --channels-last --resume runs/long1200_paper_arch/latest.pt
# 3. 量化导出（W8A12）-> params/、manifest.json、golden/（即 data/model/ 中的 params、manifest.json）
python export_fpga.py --checkpoint runs/long1200_paper_arch/best.pt --out-dir runs/fpga_export_w8a12 --wbits 8 --abits 12
# 4. 生成 RTL：src/network/gen_rtl_init.py（-> rtl_init/）、gen_rtl_top.py、tools_create_vivado_projects.py
```

工具：Python 3 + PyTorch（CUDA）+ NumPy + Pillow。
