# Digital Galton Board

An RP2040 VGA animation demo — bouncing balls forming a binomial distribution on a
640x480 VGA display, driven by PIO state machines and dual-core protothreads.

Based on Hunter Adams' [Animation Demo](https://github.com/vha3/Hunter-Adams-RP2040-Demos/tree/master/VGA_Graphics/Animation_Demo)
from the Cornell ECE 4760 RP2040 demo collection.

## Layout

- `animation.c` — main program: physics, protothreads, core assignment
- `VGA/` — VGA driver (`vga16_graphics_v3.c`), PIO programs (`hsync`, `vsync`, `rgb`), fonts
- `pt_cornell_rp2040_v1_4.h` — Cornell protothreads library
- `CMakeLists.txt` — Pico SDK build config

## Building

You need the [Pico SDK](https://github.com/raspberrypi/pico-sdk) and `arm-none-eabi-gcc`.
Copy `pico_sdk_import.cmake` from `$PICO_SDK_PATH/external/` into this directory first —
`CMakeLists.txt` includes it and it is not checked in.

```sh
cp $PICO_SDK_PATH/external/pico_sdk_import.cmake .
mkdir build && cd build
cmake ..
make -j
```

Flash the resulting `VGA_Animation_Demo.uf2` by holding BOOTSEL while plugging in the Pico.

## Wiring

| Pico GPIO | VGA |
|---|---|
| 16 | Hsync |
| 17 | Vsync |
| 18–20 | RGB (through resistor DAC) |
| GND | VGA GND |

Check the pin definitions at the top of `VGA/vga16_graphics_v3.c` before wiring.

## Contributing

Open an issue or a pull request. Fork, branch off `main`, and keep changes focused.

## License

Upstream code is by V. Hunter Adams (vha3@cornell.edu), Cornell University.
