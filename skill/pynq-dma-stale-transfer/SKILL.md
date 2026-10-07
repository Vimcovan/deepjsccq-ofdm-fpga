---
name: pynq-dma-stale-transfer
description: Use on PYNQ (Zynq / Zynq UltraScale+) when an AXI DMA receive (S2MM) transfer can be left pending — a timeout, a process killed or stopped by systemd, a capture waiting for a trigger that never comes — and the next transfer or the next process hangs or reads nothing. Gives the soft-reset recipe that pynq's stop() does not do.
---

# PYNQ：AXI DMA 遗留传输的检测与软复位

## 适用场景

- PYNQ 上用 `pynq.lib.dma` 收数据（S2MM），而数据**不一定会来**：PL 侧等触发、等帧、上游没信号。
- 现象：等待超时后再发起传输，永远不完成；或者进程被杀 / `systemctl stop` 后，**下一个进程**的第一次传输就卡住或收不到数据；
  更隐蔽的是，遗留的传输在之后某个时刻写进了已经释放的缓冲区。

## 原因

`recvchannel.transfer(buf)` 已经把目标地址和长度写进 DMA，通道在等 PL 送数据。此时：

- `recvchannel.stop()` 只清运行位（DMACR.RS），并等待 halted；S2MM 在等数据时**不会进入 halted**，`stop()` 可能一直等下去，
  也不会撤销已经提交的描述。
- 进程退出时没人复位 DMA，硬件里的那次传输仍然挂着，下一个进程的 `transfer()` 被它挡住，或者数据被写到旧地址。

## 使用方法

S2MM 控制寄存器 DMACR 在偏移 `0x30`，bit 2 是软复位（MM2S 为 `0x00`）。复位会清掉挂起的传输，完成后位自动清零，再重新启动通道：

```python
import time

def dma_reset(dma, timeout=0.1):
    """AXI DMA soft reset (S2MM DMACR bit 2) and restart: drops a pending receive transfer."""
    dma.mmio.write(0x30, 0x4)
    t0 = time.time()
    while dma.mmio.read(0x30) & 0x4 and time.time() - t0 < timeout:
        pass
    dma.recvchannel.start()
```

三处要用：

1. **等待超时后**：先 `dma_reset`，再报错或重试（不要调 `stop()`）。
2. **进程退出时**：在 `finally` 或 SIGTERM 处理里复位所有接收 DMA。若还有别的线程会发起传输，先拿到同一把锁再复位，防止复位后又被提交新的传输。
3. **缓冲区生命周期**：超时后缓冲区不要立即释放（遗留传输可能稍后写入），按对象生命周期持有，或者先复位再释放。

```python
try:
    serve()
finally:
    lock.acquire(timeout=3)          # no thread starts another transfer after the reset
    dma_reset(ol.cap_dma); dma_reset(ol.img_dma)
```

同一个 AXI DMA 的 MM2S 与 S2MM 共用复位：如果两个方向同时在用，复位会打断另一个方向，需要一起重启。

## 已验证效果

本项目 RX 板（PYNQ-ZU，PYNQ 3.1）：`rx_server.py` 在 `systemctl stop` 时复位抓取与图像两个 DMA，日志打印
`rx_server stopped, DMAs reset`；验证：TX 关机（ADC 抓取等不到帧触发）时停掉服务，新进程的抓取能正常完成；图像 DMA 超时后自动恢复，
长时间运行不再出现卡死。实现见 `src/sw/rx/jscc_rx.py` 的 `_dma_reset`、`src/sw/rx/rx_server.py` 末尾。

## 来源（从哪次失败中总结）

2026-10-06 排查显示杂散时，需要在 TX 关机的条件下抓 ADC 数据。停掉 `jscc-rx` 服务后，新的抓取进程始终拿不到数据：
`rx_server` 的频谱线程退出前留下了一个"等下一帧"的抓取传输，TX 没信号，这个传输永远不会完成。查 pynq 源码确认 `stop()`
只清运行位、不撤销传输，于是改为写 DMACR 软复位。图像通道此前已因"超时后再也收不到"用过同样的办法，ADC 抓取通道当时漏掉了。
