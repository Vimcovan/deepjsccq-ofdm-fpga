# mali400-offscreen-gles — Prompt Library

Copy-paste prompts for an agent that has this skill loaded. Replace the ssh target with your board.

## Getting Started

**Check the GPU and run the smoke test (recommended first prompt):**
```
My PYNQ-ZU board (ssh root@<board-ip>) draws 3-D plots very slowly with OpenGL. Check whether the board's GPU can be used; if it can, run a test and show me the image and the timing.
```

**Probe only, change nothing:**
```
Only check (read-only) whether the Mali-400 on my ZynqMP board can be used under this Linux image: driver, device tree, Mesa. Do not load or install anything.
```

## Driver

**Driver missing:**
```
lima is not in the kernel. Build it and its dependencies as external modules and load them temporarily so we can test the GPU.
```

**Make it permanent (after the test passed):**
```
The GPU test passed. Load lima automatically at boot and tell me how to undo it.
```

## Integration

**Add a GPU-rendered view to an existing Qt GUI:**
```
Add a 3-D surface of <data> to my PyQt GUI (<file>), rendered on the Mali-400 in a separate process; keep a 2-D fallback when the GPU is not available.
```

**Performance budget:**
```
How large can the rendered image be and how often can it refresh if the renderer may use at most 10 % of one core?
```

## Troubleshooting

**Only the background colour comes out:**
```
The off-screen renderer suddenly returns only the clear colour and prints no error. What happened and how should the program recover?
```

**Wrong renderer:**
```
GL_RENDERER prints llvmpipe instead of Mali400. Find out why.
```
