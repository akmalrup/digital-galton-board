#set document(
  title: "ECE 4760 Lab 2: Digital Galton Board",
  author: ("TODO: Name 1", "TODO: Name 2"),
)
#set page(
  paper: "us-letter",
  margin: 1in,
  numbering: "1",
)
#set text(font: "New Computer Modern", size: 11pt)
// Number only the main sections ("1.", "2.", ...); subheadings stay unnumbered
#set heading(numbering: (..n) => if n.pos().len() == 1 { numbering("1.", ..n) })
#set par(justify: true, leading: 0.65em)
#show link: set text(fill: blue)

#let todo(body) = text(fill: rgb("#b45309"), style: "italic")[TODO: #body]

#align(center)[
  #text(size: 16pt, weight: "bold")[ECE 4760 / 5730 --- Lab 2]
  #v(0.4em)
  #text(size: 20pt, weight: "bold")[Digital Galton Board]
  #v(0.6em)
  #text(size: 12pt)[
    Akmal Rupasingha, Demetrios Gavalas, Parishee Bajaj\
    Cornell University \
    ECE 5730 Thursday 4:30 \u{00B7} #datetime.today().display("[month repr:long] [day], [year]")
  ]
]

#v(1em)
#outline(indent: auto, depth: 2)
#pagebreak()

// ============================================================
= Introduction
// ============================================================

A Galton board is a board covered in rows of pegs. A ball dropped in at the top bounces off one peg in each row and lands in one of the bins at the bottom. In an ideal board, each bounce is like a coin flip where a 50%  chance of going left and a 50% chance of going right is possible. That means the number of balls in each bin follows a binomial distribution and with enough rows and balls, the central limit theorem says this turns into a bell-shaped Gaussian curve. In this lab, we built a digital version of a galton board on the RP2350 and showed it on a VGA screen. Balls fall through 16 rows of pegs and bounce off them using collision physics. Every time the ball hits a peg it makes a sounds that is played with DMA - this is done so that it does not slow the CPU down. A live histogram at the bottom of the screen counts how many balls land in each bin so that you are able to watch the Gaussian curve form. A rotary encoder lets the user change the number of balls, the bounciness, the gravity, and the ball while the animation runs. Our main goal was to animate as many balls as possible at 60 FPS, and our final design ran \~19k balls without missing timing. 

// ============================================================
= Design and Testing Methods
// ============================================================

== System overview

The final baseline system uses the Pico 2 board with two peripheral devices. The first is a rotary encoder, which exposes terminals which tell us the direction of rotation and whether or not the encoder is pushed down. This encoder is used for user input. The second is the VGA screen. The VGA connector connects to the board via adjacent GPIO pins. 

The program is split into several different interrupt handlers and threads. The peripherals are handled by interrupts. The rotary encoder interrupt is triggered by the debounced A pin. VGA interrupts are triggered on the VSYNC and HSYNC pins to keep timing on the VGA screen accurate. 

The graphics library uses a double-buffered system. One buffer is the active buffer which is written to the monitor by the PIO state machine example code. The other buffer is written to by the graphics library. At the end of a frame time, the buffer pointers are swapped. This prevents the screen tearing when graphics are drawn as the pixels are being read onto the screen. 

In our baseline implementation, all the graphics are drawn in a single thread. The thread generates the same peg positions each time, and then it reads the ball positions from a statically allocated array of structs. 

The ball physics are handled in a separate thread. This thread calls two important functions, one function updates gravity and edge handling for all the balls. The other thread handles collisions between a single ball and a single peg. In our baseline implementation, each ball is checked against every peg for collisions. 

The rotary encoder interrupt handlers handle rotations and pushes of the encoder. A push changes the mode of the encoder control to control different parameters, stored as an enum. Then, rotating the encoder triggers its own handler, which checks the other encoder pin level to increment or decrement the counter value. 

== Hardware
The main components of the system are the RP2350, rotary encoder, VGA connector PCB, DAC, & the onboard LED. 

The rotary encoder was the main way that users would be able to interact with the system. The encoder could be used both as a push button and a rotary knob. The push button let users cycle through different parameters of the galton board while the rotary knob let users numerically change values of the parameters themselves. 

Since the rotary encoder is a mechanical device, it is prone to bouncing in the same way the keypad was in lab 1. Instead of using a debouncing software finite state machine, we chose to implement a solution in hardware. If we used the software implementation, we would had to run the FSM each time the encoder was rotated or pressed which would have increased the size of our interrupt service routine. This would be disadvantageous when we tried to run as many balls as possible at 60 FPS because it would add 4 additional steps to each ball we rendered. Instead, we used a 0.01 uF capacitor in parallel to ground with output A of the encoder. This would smooth out any rapid unwanted changes in the output of the encoder and prevent the ISR from being falsely triggered. The reason that we chose to debounce output A instead of output B is because we triggered the ISR on the changing edge of output A, so we didn't need to debounce output B.

We also tied the onboard LED on GPIO 25 to a timer that would toggle the LED if the system could not finish a frame at 60 FPS. This would show us if we were actually hitting timing even if our eyes could not tell the difference on the VGA display. 

We used the MCP4822 DAC to output a sound to the speaker. This is the same DAC that we used in the lab 1, but now we used it to output a thunk sound every time a ball hit a peg. 

We interfaced with the VGA display in the same way we did in lab 1, using the PCB that we were provided. The PCB also had the correct resistors the GPIO needed to get the VGA to function correctly. 

== Software

=== Ball physics
The ball physics are a modified version of the pseudocode on the course website. Each ball is stored as a struct of four fix15 numbers: its x and y position and its x and y velocity. Using fixed point instead of floats keeps most of the math as integer adds and multiplies, which are much cheaper on the RP2350.

In our baseline implementation, the physics run in a simple loop. At the start of each frame, it does two passes over the balls. The first pass calls `updateBallPhysics` on every ball. This function adds the velocity to the position, adds gravity to the y velocity, and handles the edges of the screen. If a ball hits the left or right wall, it is placed back on the wall and its x velocity is flipped. If a ball falls past the bottom of the screen, we work out which histogram bin it landed in from its x position, add one to that bin and to the count of fallen balls, and then respawn the ball at the top of the board with zero velocity. The second pass checks every ball for collisions with the pegs, which is described in the next section.

=== Peg collisions
In the baseline implementation, peg collisions are checked after every ball has been moved. For every one of the 136 pegs, we loop over every ball and call `checkBallCollision`. If the ball is touching the peg, we find the unit vector pointing from the peg to the ball, which needs two divides. The ball is moved out to the edge of the peg along that vector so it doesn't get stuck inside, and its velocity is reflected about that vector if it is moving into the peg. Finally, the collision starts the DMA thunk sound. 

This version is easy to follow, but it is slow. Every ball is checked against every peg every frame, so the collision pass does $136 times N$ checks for $N$ balls, even though a ball can only ever be near one or two pegs. On top of that, each real collision uses a `sqrt` and two divides in floating point, which the RP2350 has to convert to and from fix15. These are the main costs we went after in the optimizations section.

To cut down the number of checks, we used the fact that the pegs are in a fixed grid. A ball can only hit a peg if their centers are closer than the ball’s radius plus the peg’s radius, which is at most 16 pixels. The rows are 19 pixels apart, so only 2 rows at most can be that close to a ball vertically. The pegs in a row are 38 pixels apart, so only the closest peg in each row can be close enough horizontally. Using the ball’s position, we divide by the peg spacing to find which rows are nearby and which peg in each row is closest. Then we look up that peg in the array and run the exact collision check on just that peg. Balls that are above the top row or below the bottom row skip the check completely. This means each ball needs at most 2 collision checks instead of 136, which made Core 1’s physics loop much faster. It was one of our first big jumps in ball count, and it was part of the round of changes that took us from 850 to 3,000 balls.

=== Board layout and histogram
The board is a triangle of 136 pegs in 16 rows. The first row has one peg and each row after it has one more, so the last row has 16. The top peg sits at the center of the screen at $(320, 100)$, and the rows are 19 px apart. Within a row, the pegs are 38 px apart, so each peg sits directly between the two pegs below it. This means a ball that bounces off a peg lands on one of the two pegs in the next row, just like a real Galton board. The peg positions are computed once at startup and stored row by row in a statically allocated array, so peg number $c$ in row $r$ is at $x = 320 + (2c - r) dot 19$ and $y = 100 + 19r$. Balls spawn above the top peg at $x = 320$, so every ball starts by hitting the first peg.

The histogram at the bottom of the screen has 17 bins, one for each gap the ball can fall through below the last row: the 15 gaps between the 16 pegs, plus one on each side. Each bin is 38 px wide, and the bins are lined up so that their edges fall directly under the pegs in the bottom row, with the middle bin centered under the top peg. When a ball falls past the bottom of the screen, the physics thread finds its bin by subtracting the left edge of the histogram from the ball's x position and dividing by the bin width, then adds one to that bin.

Each frame, the drawing thread scales the bars so that the tallest bin is 80 px high and the others are drawn in proportion to it. This way the histogram always fits under the board no matter how many balls have fallen. The count for each bin is printed above its bar. Whenever the user turns or presses the encoder, the encoder interrupt clears the histogram and the count of fallen balls, so the distribution starts over with the new settings.

=== DMA thunk sound
Each time a ball hits a peg, the speaker plays a short thunk. Since collisions can happen thousands of times a second, we didn't want the CPU to spend any time sending audio samples to the DAC. Instead, the sound is played entirely by a DMA channel, and the physics thread only has to start it.

At startup, we fill a 256-entry table with one period of a sine wave multiplied by a decaying envelope, so each period starts loud and fades out. Each entry already has the MCP4822 configuration bits for channel A in its upper 4 bits, so it is a complete 16-bit SPI word that can be sent straight to the DAC. The table is aligned to 512 bytes so that the DMA channel can use ring-buffer wrapping on its read address.

The DMA channel reads from the table and writes to the SPI data register, with the read address incrementing and the write address fixed. Instead of being paced by the SPI, it is paced by a DMA timer set to $1/3401$ of the system clock, which is about 44 kHz at 150 MHz. With the read address wrapping every 512 bytes, the channel loops through the table on its own without needing a second control channel to reset it. The channel is configured at startup but not started.

When `checkBallCollision` detects a hit, it calls `dma_chirp`, which writes a transfer count of $5 times 256 = 1280$ samples to the channel and starts it. The DMA then plays five periods of the table (about 29 ms) and stops by itself. The thunk plays on every collision, not just the first time a ball reaches a new peg. Starting the sound is a single register write, so it costs the physics thread almost nothing. If another collision happens while a thunk is still playing, the channel is already busy and the new trigger is ignored, so with many balls the thunks blend into a steady rattle instead of piling up.

=== Encoder modes and on-screen display

The user controls the simulation with the rotary encoder. Turning the knob changes a setting, and pressing it down switches which setting is being changed. Each press moves to the next mode in this order: number of balls, bounciness, gravity, and ball radius. After ball radius, it goes back to number of balls. The button uses a falling-edge interrupt.

To read the knob, we set an interrupt on the falling edge of channel A. When it fires, we read channel B. If B is high, the knob turned one way, and we add 1. If B is low, it turned the other way, and we subtract 1. Each click changes the current setting by one step. Number of balls changes by 1, from 0 up to 24,000. Bounciness changes by 0.01, from 0 to 1.00. Gravity changes by 0.01 and is allowed to go negative. With negative gravity, the balls “fall” upward and pile up at the top of the screen. Ball radius changes by 1 pixel, from 1 to 10.

Any time the user turns the knob or presses the button, the histogram and the count of fallen balls reset to zero. That way the histogram only shows balls that fell with the current settings.

The top-left corner of the screen shows the total number of balls that have fallen, the seconds since boot, and the current value of all four settings. The active setting was originally highlighted in blue. After we switched the display to 1-bit color to save memory, the screen could only show black and white, so the highlight stopped showing up. Below the settings, the screen shows timing for each frame. That includes how long Core 1 spent on physics and how long Core 0 spent drawing, out of the 60hz frame budget. We used these timers to find what was slowing us down while we optimized.

== Optimizations
We measured success by the number of balls we could run while every frame still finished within 16.67 ms (60 fps), which means the deadline LED stays off. We recorded the new maximum after each round of changes. @tab:opt sums up the steps, and the paragraphs below explain each one.

#figure(
  table(
    columns: (1.3fr, 2.6fr, 1fr),
    inset: 6pt,
    align: (left, left, right),
    stroke: 0.5pt,
    table.header[*Step*][*What changed*][*Max balls at 60 fps*],
    [Starting point], [Physics on Core 1, drawing on Core 0], [450],
    [Semaphore fix], [Core 0 draws balls while Core 1 runs physics], [850],
    [Faster collisions], [Outline-only drawing, alpha-max-beta-min distance, only check nearby pegs], [3,000],
    [Radius-1 balls], [Balls shrunk to 1 px with a fast drawing path], [10,000],
    [1-bit color], [Frame buffers shrunk to 1 bit per pixel to free memory], [14,000],
    [Overclock], [System clock raised from 150 MHz to 200 MHz], [#todo[number]],
  ),
  caption: [Maximum number of balls at 60 fps after each optimization.],
) <tab:opt>

*Semaphore fix.* At first, Core 0 told Core 1 to start the physics, drew the pegs and text, and then waited for Core 1 to finish before drawing the balls. This meant drawing the balls and doing the physics never happened at the same time. We moved the "start" signal to the very beginning of the frame and moved the wait to the very end, after the balls are drawn. Now both cores work for almost the whole frame, which roughly doubled the ball count.

*Faster collisions.* These changes made Core 1's physics loop much cheaper:
- We switched from filled shapes to outlines (`drawCircle` and `drawRect` instead of `fillCircle` and `fillRect`), so each ball, peg, and bar sets fewer pixels.
- We replaced the floating-point `sqrt` in the collision check with the alpha-max-beta-min approximation, which only needs a compare, a shift, and an add. Finding the direction of the bounce now takes one divide instead of two.
- Before, every ball was checked against all 136 pegs every frame. Since the rows are 19 px apart and the pegs in a row are 38 px apart, a ball can only touch the nearest peg in at most 2 rows. We work out those pegs directly from the ball's position, so each ball needs at most 2 collision checks instead of 136.

*Radius-1 balls.* We shrank the balls to a radius of 1 pixel. We also added a shortcut to `drawCircle` for a radius of 1. The normal circle algorithm only lights 4 pixels at that size, but it draws each of them 3 times, so the shortcut just draws the 4 pixels once.

*1-bit color.* At this point we ran out of memory, not time. The RP2350 has 520 KB of SRAM. The two VGA frame buffers at 4 bits per pixel took 2 #sym.times 153,600 = 307,200 bytes, and each ball takes 16 bytes (four fix15 numbers), so we could only fit about 12,500 balls. Since we didn't need color, we changed the VGA driver & the PIO program to use only 1 bit per pixel. Previously, each byte stored 2 pixels to allow for 4-bit color, but we wanted to compress the information of 8 pixels into 1 byte. We still had to output 4 bits worth of information per pixel to the VGA, so in the PIO program, we would take each bit from the shift register and repeat it 4 times to the VGA. This also meant that we could only output either 0000 or 1111 to the VGA, which is black or white. Previously, we were using different colors to show the user what parameter they had selected to change, but after this change, we made the text blink to indicate which entry was selected. This change shrunk each buffer to 38,400 bytes and frees 230,400 bytes, enough for about 14,400 more balls. 


*Overclock.* We raised the system clock from 150 MHz to 200 MHz. To keep the VGA timing correct, we changed the PIO clock dividers from 6 to 8 (so the PIO still runs at 25 MHz) and adjusted the delays in the RGB program.

*Things we tried and undid.* #todo[Why were these reverted?]
- Stochastic rounding
- Separate protothreads for the text and the histogram

== Testing

#figure(
  table(
    columns: (1.4fr, 1.6fr, 1.4fr),
    inset: 6pt,
    align: left,
    stroke: 0.5pt,
    table.header[*Requirement*][*Test*][*Pass criterion*],
    [Encoder rotating CW/CCW], [Rotate while watching VGA count], [Increments / decrements reliably],
    [One ball, one peg], [Drop, collide, thunk, respawn], [Audible thunk; gravity; auto-respawn],
    [16-row board $>=$ 10 balls], [Watch VGA], [All collide, thunk, respawn],
    [Live stats], [VGA overlay], [Active balls, total fallen, time since boot],
    [Histogram], [Let balls build up], [17 bins; bars fit under the board],
    [Encoder modes], [Click through modes], [VGA shows mode; rotating encoder edits that setting],
    [Setting change resets stats], [Turn encoder mid-run], [Histogram and total fallen go to 0],
    [Deadline LED], [Overload the system (increase ball count, increase radius, etc.)], [LED on only when frame $>$ 16.67 ms],
  ),
  caption: [Verification tests.],
)

== AI use
#todo[Tools used, what they generated, what we kept, and how we checked it. AI-written code is labeled in Appendix A; full prompt log in Appendix B.]

// ============================================================
= Documentation
// ============================================================

== Wiring diagram
#figure(
  image("figures/IMG_0559.jpeg", width: 100%),
  caption: [Wiring connections between the Pico, rotary encoder, VGA PCB, and audio DAC.],
) <fig:wiring>

== Software System Diagram
#figure(
  image("figures/frame-flowchart.png", width: 90%),
  caption: [One frame of the program. Core 0 draws while Core 1 runs the physics.],
) <fig:flow>

== Rotary Encoder Diagram
#figure(
  image("figures/rotary_diagram.png", width: 100%),
  caption: [Rotary encoder contact sequence during rotation. ECE 4760 course webpage, #link("https://vanhunteradams.com/Pico/Galton/Rotary_Encoder.html")[How does a rotary encoder work?].],
) <fig:rotary>


// ============================================================
= Results
// ============================================================

== Final Product
#figure(
  image("figures/IMG_7917.jpeg", width: 100%),
  caption: [Our final digital Galton board running on the VGA display, showing the animated balls, pegs, live histogram, simulation settings, and frame timing.],
) <fig:final-product>

== Speed
#todo[Final max balls at 60 fps (see @tab:opt for how we got there). Physics / draw / frame time breakdown from the on-screen timers.]

== Accuracy
#todo[Screenshot of the board and histogram, compared to the ideal $B(16, 1/2)$. Sources of error (missed pegs, balls passing through pegs, spawn bias, fixed-point rounding).]

Visually, the galton board seemed to be accurate and result in the expected Gaussian distribution. Although, 

== Effect of settings
As we increased ball radius, we decreased the maximum number of balls we could run at 60 fps. This was not only because the system spent more time drawing more pixels for each ball, but also because the larger balls had more frequent collisions with pegs and each other. This would lead to our physics thread running more often and taking longer to finish.

The way that we changed bounciness of the balls was by changing the percentage of the velocity that was retained after each collision. Increasing the bounciness of the balls also decreased the maximum number of balls we could run at 60 fps. This is because the bouncier the balls are the more frequent collisions which would lead to our physic thread running more often & taking longer to finish. 

Changing the gravity added a downward velocity to the balls. We didn't notice a significant change in our maximum number of balls as we changed the gravity, but having 0 gravity changed the distribution of our balls in the histogram.

// ============================================================
= Conclusions
// ============================================================
#todo[How usable it was, what we would do differently, and feedback on the lab.]

The system in all seemed to be user-friendly, but one thing we would change is how the screen indicates what parameter is selected to change. At first, we highlighted the active setting in blue. After we switched the display to 1-bit color to save memory, the screen could only show black and white, so the blue highlight showed up as white and disappeared. If we did this again, we would put an arrow/dot in front of the active setting instead. This only uses text, so it works in black and white and doesn’t cost extra memory. It would make it much easier for the user to tell which setting the knob is about to change.

Another thing we would change if we were to revisit this lab, is that we had a lots of text below the parameters displaying how much time we were spending in each part of the system which was being constantly updated. This was very useful during the design phase to find where we were getting bottlenecked, but we had this text displayed in our final demo as well. This was not a requirement to get checked off and likely marginally reduced our performance. If we were to do this again, we would remove the text from the final demo an an effort to get more balls. 
// ============================================================
= Lab Questions
// ============================================================

== Question 1
_Our physical model of the Galton Board differs from the idealized model. In order for the Central Limit Theorem to hold, all random numbers must be *independent*, *identically distributed*, and have *finite variance.* Which of these assumptions hold for our physical Galton Board model, and which do not? Why do we still see a distribution that approaches a Gaussian? (You needn't prove anything here, just try to identify the generalization of the CLT that is responsible for this)._

In our galton board, the random variable is the direction the ball takes at each peg. For our Galton board, the only one of these assumptions which actually holds is that the variance is finite, because the force on the ball is always bounded and so the amount the ball can move sideways is finite. The impulses on the ball are not independent (the previous bounce affects the current bounce) nor identically distributed (some bounces can skew left or right). However, while they aren't independent, they are weakly dependent. When summing many bounded, weakly dependent steps the randomness seems to dominate, and result in a Gaussian distribution.  

== Question 2
_The Gaussian approximates the distribution under the Galton board *better* with *more rows in the board*. Why?_
With more rows in the board, there are more random variables that each ball's final position depends on. The central limit theorem holds for repeatedly sampling a random variable, so adding rows is effectively adding samples of the random variable.

== Question 3
_For your 16-row Galton Board, what is the mean and standard deviation of the Gaussian which approximates the resulting distribution (under the assumption that your Galton Board is "ideal")?_

In an ideal board, each of the 16 rows is an independent random variable with $p = 1/2$ of going right, so the bin a ball lands in follows a binomial distribution $B(16, 1/2)$. The Gaussian that approximates it has

$ mu = n p = 16 dot 1/2 = 8, quad sigma = sqrt(n p (1 - p)) = sqrt(16 dot 1/2 dot 1/2) = 2 $

where bins are numbered 0 to 16. So the curve is centered on the middle bin (bin 8), and about 68% of balls should land within 2 bins of it. On our screen, where each bin is 38 px wide, this is a mean of $x = 320$ px (under the top peg) and a standard deviation of 76 px.

// ============================================================
#heading(numbering: none)[Appendix A --- Commented Program Listing]
// ============================================================
#todo[Full commented source with AI-written parts marked.]

// Keep the pasted listing literal and apply formatting only inside this block.
#block(
  width: 100%,
  breakable: true,
  fill: rgb("#f5f5f5"),
  stroke: 0.5pt + rgb("#dddddd"),
  radius: 3pt,
  inset: 10pt,
)[
#set text(size: 8pt)
#set par(justify: false, leading: 0.45em)
```c
/**
 * ECE 4760 / 5730 - Lab 2 (Digital Galton Board)
 * encoder.c
 */

#include "VGA/vga16_graphics_v3.h"

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <time.h>

#include "pico/stdlib.h"
#include "pico/divider.h"
#include "pico/aon_timer.h"
#include "pico/multicore.h"
#include "pico/sync.h"

#include "hardware/pio.h"
#include "hardware/dma.h"
#include "hardware/spi.h"
#include "hardware/clocks.h"
#include "hardware/pll.h"
#include "hardware/gpio.h"

#include "pt_cornell_rp2040_v1_4.h"

//
// ENCODER DEFS
//
#define ENC_A 14
#define ENC_B 15
#define PUSHBUTTON 13
#define LED_PIN 25

#define BOTH_SHORTED  0
#define A_SHORTED     1
#define B_SHORTED     2
#define NEITHER       3

//
// ADC / SPI / DMA DEFS 
// 

#define sine_table_size 256
#define CHIRP_PERIODS   5
#define CHIRP_SAMPLES   (CHIRP_PERIODS * sine_table_size)

// Sine table aligned to 512 bytes (2^9) for hardware ring-buffer wrapping
__attribute__((aligned(512))) unsigned short DAC_data[sine_table_size];

// A-channel, 1x, active
#define DAC_config_chan_A 0b0011000000000000

// SPI configurations
#define PIN_MISO 4
#define PIN_CS   5
#define PIN_SCK  6
#define PIN_MOSI 7
#define SPI_PORT spi0


// histogram parameters

#define HIST_HEIGHT 80
#define NUM_BINS    17
#define BIN_WIDTH   38
// x of bin 0's left edge. Chosen so the middle bin (8) spans [301, 339),
// centered on the board's center x = 320, with bin edges on the bottom-row pegs
#define HIST_LEFT   (320 - BIN_WIDTH / 2 - (NUM_BINS / 2) * BIN_WIDTH)

int data_chan;

void dma_chirp(void) {
    dma_channel_set_trans_count(data_chan, CHIRP_SAMPLES, true);
}

void init_dma_chirp(void) {
    //fills in sine table with decaying envelope
    for (int i = 0; i < sine_table_size; i++) {
        float progress = (float)i / (float)sine_table_size;
        float envelope = (1.0f - progress) * expf(-2.5f * progress);
        int raw_sin = 2048 + (int)(2047.0f * envelope * sinf((float)i * 6.28318530718f / (float)sine_table_size));
        DAC_data[i] = (unsigned short)(DAC_config_chan_A | (raw_sin & 0x0FFF));
    }

    //initializes SPI for the DAC
    spi_init(SPI_PORT, 20000000);
    spi_set_format(SPI_PORT, 16, 0, 0, 0);
    gpio_set_function(PIN_MISO, GPIO_FUNC_SPI);
    gpio_set_function(PIN_CS,   GPIO_FUNC_SPI);
    gpio_set_function(PIN_SCK,  GPIO_FUNC_SPI);
    gpio_set_function(PIN_MOSI, GPIO_FUNC_SPI);

    // Initial neutral mid-scale output
    uint16_t neutral = DAC_config_chan_A | 2048;
    spi_write16_blocking(SPI_PORT, &neutral, 1);

    //initialize timer for DMA channel transaction
    int audio_timer = dma_claim_unused_timer(true);
    dma_timer_set_fraction(audio_timer, 1, 3401);

    data_chan = dma_claim_unused_channel(true);

    dma_channel_config c_data = dma_channel_get_default_config(data_chan);
    channel_config_set_transfer_data_size(&c_data, DMA_SIZE_16);
    channel_config_set_read_increment(&c_data, true);
    channel_config_set_write_increment(&c_data, false);
    channel_config_set_ring(&c_data, false, 9); // 2^9 = 512 bytes (256 samples of uint16)
    channel_config_set_dreq(&c_data, dma_get_timer_dreq(audio_timer));

    dma_channel_configure(
        data_chan,
        &c_data,
        &spi_get_hw(SPI_PORT)->dr,
        DAC_data,
        0,
        false
    );
}

//fixed point functions
typedef signed int fix15;
#define multfix15(a,b) ((fix15)((((signed long long)(a))*((signed long long)(b)))>>15))
#define float2fix15(a) ((fix15)((a)*32768.0))
#define fix2float15(a) ((float)(a)/32768.0)
#define absfix15(a) abs(a)
#define int2fix15(a) ((fix15)(a << 15))
#define fix2int15(a) ((int)(a >> 15))
#define divfix(a,b) (fix15)(div_s64s64((((signed long long)(a)) << 15), ((signed long long)(b))))

#define PEG_RADIUS  6

volatile fix15 gravity = float2fix15(0.6);
volatile fix15 bounciness = float2fix15(0.3);

#define MAX_NUM_BALLS 24000
volatile int num_balls = 18000;
volatile int fallen_balls = 0;
volatile int encoder_count = 0;

//set ball_radius to 1 to optimize
volatile int ball_radius = 1;

typedef enum {
    BALLS,
    _BOUNCINESS,
    _GRAVITY,
    _ball_radius,
    MAX_STATE,
} pusher_state_t;

volatile pusher_state_t pusher_state = BALLS;
int histogram[NUM_BINS] = {0};

semaphore_t sem_physics_start;
semaphore_t sem_physics_done;

void reset_histogram() {
    for (int i = 0; i < NUM_BINS; i++) {
        histogram[i] = 0;
    }
}

void gpio_callback(uint gpio, uint32_t event_mask) {
    if (gpio == ENC_A) {
        //checks state of B to see what way the encoder is being turned
        int enc_b_read = gpio_get(ENC_B);
        int enc_incr = (enc_b_read) ? 1 : -1;
        encoder_count += enc_incr;

        if (pusher_state == BALLS) {
            num_balls += enc_incr;
            if (num_balls < 0) {
                num_balls = 0;
            } else if (num_balls > MAX_NUM_BALLS) {
                num_balls = MAX_NUM_BALLS;
            }
        } else if (pusher_state == _BOUNCINESS) {
            if (enc_incr > 0) {
                bounciness += float2fix15(0.01);
            } else {
                bounciness -= float2fix15(0.01);
            }
            if (bounciness < 0) bounciness = 0;
            if (bounciness > float2fix15(1.0)) bounciness = float2fix15(1.0);
        } else if (pusher_state == _GRAVITY) {
            if (enc_incr > 0) {
                gravity += float2fix15(0.01);
            } else {
                gravity -= float2fix15(0.01);
            }
        } else if (pusher_state == _ball_radius) {
            if (enc_incr > 0) {
                ball_radius += 1;
            } else {
                ball_radius -= 1;
            }
            if (ball_radius < 1) ball_radius = 1;
            if (ball_radius > 10) ball_radius = 10;
            if (gravity < 0) gravity = 0;
            if (gravity > float2fix15(5.0)) gravity = float2fix15(5.0);
        }
    } else if (gpio == PUSHBUTTON) {
        static uint64_t last_press_time = 0;
        uint64_t now = to_us_since_boot(get_absolute_time());
        if (now - last_press_time > 200000) {
            last_press_time = now;
            pusher_state = (pusher_state_t)((pusher_state + 1) % MAX_STATE);
        }
    }

    //reset histogram & total balls each time the total number of balls changes
    reset_histogram();
    fallen_balls = 0;
}

//typdef to hold position & velocity of each ball
typedef struct {
    fix15 x;
    fix15 y;
    fix15 vx;
    fix15 vy;
} boid_t;

typedef struct {
    fix15 x;
    fix15 y;
} peg_t;



boid_t ball[MAX_NUM_BALLS];

peg_t peg [136];
char color = WHITE;
static int last_peg = -1;

void spawnBall(boid_t* b) {
    // random sub-pixel offset in [-2, 2) px around center (0x1FFFF = 4 px in fix15)
    b->x = int2fix15(318) + (rand() & 0x1FFFF);
    b->y = float2fix15(56.5);
    b->vx = 0;
    b->vy = 0;
}

static inline fix15 dist_amax_bmin(fix15 dx, fix15 dy) {
    fix15 ax = absfix15(dx);
    fix15 ay = absfix15(dy);
    return (ax > ay) ? ax + (ay >> 1) : ay + (ax >> 1);
}

void checkBallCollision(boid_t* b, peg_t* p) {
    fix15 col_dist = int2fix15(ball_radius + PEG_RADIUS);

    fix15 dx = b->x - p->x;
    fix15 dy = b->y - p->y;

    if (absfix15(dx) < col_dist && absfix15(dy) < col_dist) {
        fix15 distance = dist_amax_bmin(dx, dy);

        if (distance > 0 && distance < col_dist) {

            if (absfix15(dx) < float2fix15(0.5)) {
                dx = (rand() & 1) ? int2fix15(2) : -int2fix15(2);
                distance = dist_amax_bmin(dx, dy);
            }

            // one divide, then multiply both components by 1/distance
            fix15 inv_dist = divfix(int2fix15(1), distance);
            fix15 normal_x = multfix15(dx, inv_dist);
            fix15 normal_y = multfix15(dy, inv_dist);

            fix15 intermediate_term = -2 * (multfix15(normal_x, b->vx) + multfix15(normal_y, b->vy));

            fix15 teleport_dist = int2fix15(PEG_RADIUS + ball_radius + 1);
            b->x = p->x + multfix15(normal_x, teleport_dist);
            b->y = p->y + multfix15(normal_y, teleport_dist);

            if (intermediate_term > 0) {
                b->vx += multfix15(normal_x, intermediate_term);
                b->vy += multfix15(normal_y, intermediate_term);
            }

            b->vx = multfix15(bounciness, b->vx);
            b->vy = multfix15(bounciness, b->vy);

            dma_chirp();

        }
        return;
    }

}

void updateBallPhysics(boid_t* b) {
    b->x += b->vx;
    b->y += b->vy;

    if (b->y > int2fix15(480 - ball_radius)) {
        int x_pixel = fix2int15(b->x);
        int bin = (x_pixel - HIST_LEFT) / BIN_WIDTH;
        if (x_pixel >= 0 && bin >= 0 && bin < NUM_BINS) {
            histogram[bin]++;
        }
        spawnBall(b);
        fallen_balls++;
        return;
    }

    if (b->x < int2fix15(35 + ball_radius)) {
        b->vx = -b->vx;
        b->x = int2fix15(35 + ball_radius);
    } else if (b->x > int2fix15(605 - ball_radius)) {
        b->vx = -b->vx;
        b->x = int2fix15(605 - ball_radius);
    }

    if (b->y < int2fix15(ball_radius)) {
        b->vy = -b->vy;
        b->y = int2fix15(ball_radius);
    }

    b->vy += gravity;
}

// Peg grid layout (must match the peg setup loop in main):
//   row number `row` (0..15) is at   y = PEG_TOP_Y + row * PEG_SPACING
//   peg `col` (0..row) in that row:  x = PEG_CENTER_X + (2*col - row) * PEG_SPACING
//   position of that peg in peg[]  = row*(row+1)/2 + col  (rows stored back to back)
#define PEG_ROWS      16
#define PEG_TOP_Y     100
#define PEG_CENTER_X  320
#define PEG_SPACING   19

// Check a ball only against the pegs it could be touching,
// instead of looping over all 136 pegs.
//
// A ball can only hit a peg if its center is within
// touch_distance = ball_radius + PEG_RADIUS (at most 16 px) of the peg center.
//  - Rows are 19 px apart, so at most 2 rows are close enough vertically.
//  - Pegs in a row are 38 px apart, so only the nearest peg in each row
//    can be close enough horizontally.
// So each ball needs at most 2 calls to checkBallCollision, which still
// does the exact distance test.
static inline void checkNearbyPegs(boid_t* this_ball) {
    // Ball center position in whole pixels
    int ball_x = fix2int15(this_ball->x);
    int ball_y = fix2int15(this_ball->y);

    // Ball and peg touch when their centers are closer than this
    int touch_distance = ball_radius + PEG_RADIUS;

    // Ball is completely above the first row or below the last row
    if (ball_y + touch_distance < PEG_TOP_Y) return;
    if (ball_y - touch_distance > PEG_TOP_Y + (PEG_ROWS - 1) * PEG_SPACING) return;

    // Find the rows whose y falls within
    // [ball_y - touch_distance, ball_y + touch_distance].
    // first_row rounds up and last_row rounds down, so only rows inside that
    // band are included. (C integer division truncates toward zero, which
    // rounds up for the negative values first_row can get here.)
    int first_row = (ball_y - touch_distance - PEG_TOP_Y + PEG_SPACING - 1) / PEG_SPACING;
    int last_row  = (ball_y + touch_distance - PEG_TOP_Y) / PEG_SPACING;
    if (first_row < 0)            first_row = 0;
    if (last_row > PEG_ROWS - 1)  last_row = PEG_ROWS - 1;

    for (int row = first_row; row <= last_row; row++) {
        // Leftmost peg in this row is at x = PEG_CENTER_X - row * PEG_SPACING,
        // and each next peg is 2 * PEG_SPACING to the right. Adding half
        // that gap (PEG_SPACING) before dividing rounds to the nearest column.
        int leftmost_peg_x = PEG_CENTER_X - row * PEG_SPACING;
        int nearest_col = (ball_x - leftmost_peg_x + PEG_SPACING) / (2 * PEG_SPACING);

        // Keep nearest_col on a peg that exists (this row has row + 1 pegs)
        if (nearest_col < 0)   nearest_col = 0;
        if (nearest_col > row) nearest_col = row;

        // Where that peg sits in the peg[] array
        int peg_index = row * (row + 1) / 2 + nearest_col;

        // Exact collision test against that one peg
        checkBallCollision(this_ball, &peg[peg_index]);
    }
}


int bar_heights[NUM_BINS];

void normalize_histogram(int* hist, int* heights) {
    int max = 1;
    for (int i = 0; i < NUM_BINS; i++) {
        if (hist[i] > max) {
            max = hist[i];
        }
    }
    for (int i = 0; i < NUM_BINS; i++) {
        heights[i] = (hist[i] * HIST_HEIGHT) / max;
    }
}


void draw_histogram(int* hist) {
    normalize_histogram(hist, bar_heights);

    for (int i = 0; i < NUM_BINS; i++) {
        if (bar_heights[i] > 0) {
            drawRect(HIST_LEFT + i * BIN_WIDTH, 480 - bar_heights[i],
                     BIN_WIDTH - 2, bar_heights[i], BLUE);
        }
        // print count at bin

        char buf[32];
        setTextColor(WHITE);
        setCursor(HIST_LEFT + i * BIN_WIDTH, 480 - bar_heights[i] - 10);
        sprintf(buf, "%d", histogram[i]);
        writeString(buf);
    }
}



// Core 1 physics step time, written by core 1, read by core 0 for display
volatile uint32_t physics_us = 0;

void core1_main() {
    while (1) {
        sem_acquire_blocking(&sem_physics_start);
        uint32_t t0 = time_us_32();

        for (int i = 0; i < num_balls; i++) {
            updateBallPhysics(&ball[i]);
        }

        // Resolve peg collisions, checking each ball only against
        // the pegs near it (see checkNearbyPegs) rather than all 136
        for (int i = 0; i < num_balls; i++) {
            checkNearbyPegs(&ball[i]);
        }

        physics_us = time_us_32() - t0;
        sem_release(&sem_physics_done);
    }
}

static PT_THREAD (protothread_anim(struct pt *pt))
{
    PT_BEGIN(pt);

    static char buf[48];
    static bool missed = false;
    // static: protothread locals don't survive PT_SEM_SDK_WAIT's yield
    static uint32_t start, draw_us, frame_us;
    // per-stage draw times (core 0), shown on screen one frame late
    static uint32_t mark, clear_us, pegs_us, hist_us, text_us, balls_us;

    for (int i = 0; i < MAX_NUM_BALLS; i++) {
        spawnBall(&ball[i]);
    }

    while (1) {
        PT_YIELD_UNTIL(pt, draw_start_signal());
        //check if we are meeting the 60 fps deadline 
        start = time_us_32();

        sem_release(&sem_physics_start);

        mark = time_us_32();
        clearLowFrame(0, BLACK);
        clear_us = time_us_32() - mark;

        // Core 0 draws pegs while Core 1 calculates physics
        mark = time_us_32();
        for (int i = 0; i < 136; i++) {
            drawCircle(fix2int15(peg[i].x), fix2int15(peg[i].y), PEG_RADIUS, WHITE);
        }
        pegs_us = time_us_32() - mark;

        // Core 0 draws histogram and UI while Core 1 calculates physics
        mark = time_us_32();
        draw_histogram(histogram);
        hist_us = time_us_32() - mark;

        // text timing covers everything from here through the stage timers below
        mark = time_us_32();
        setTextSize(1);

        // 1. Total Balls
        setTextColor(WHITE);
        setCursor(1, 50);
        sprintf(buf, "Total Balls: %d", fallen_balls);
        writeString(buf);

        // 2. Seconds since boot
        struct timespec current_time;
        aon_timer_get_time(&current_time);
        setCursor(1, 60);
        sprintf(buf, "seconds since boot: %d", (int)current_time.tv_sec);
        writeString(buf);

        // 3. Balls (active selection highlight)
        setTextColor(pusher_state == BALLS ? BLUE : WHITE);
        setCursor(1, 70);
        sprintf(buf, "Balls: %d", num_balls);
        writeString(buf);

        // 4. Bounciness (active selection highlight)
        float f_bounce = fix2float15(bounciness);
        int bounce_whole = (int)f_bounce;
        int bounce_hundredths = (int)((f_bounce - bounce_whole) * 100.0f + 0.5f);
        if (bounce_hundredths < 0) bounce_hundredths = -bounce_hundredths;
        setTextColor(pusher_state == _BOUNCINESS ? BLUE : WHITE);
        setCursor(1, 80);
        sprintf(buf, "Bounciness: %d.%02d", bounce_whole, bounce_hundredths);
        writeString(buf);

        // 5. Gravity (active selection highlight)
        float f_grav = fix2float15(gravity);
        int grav_whole = (int)f_grav;
        int grav_hundredths = (int)((f_grav - grav_whole) * 100.0f + 0.5f);
        if (grav_hundredths < 0) grav_hundredths = -grav_hundredths;
        setTextColor(pusher_state == _GRAVITY ? BLUE : WHITE);
        setCursor(1, 90);
        sprintf(buf, "Gravity: %d.%02d", grav_whole, grav_hundredths);
        writeString(buf);

        // 6. Ball Radius (active selection highlight)
        setTextColor(pusher_state == _ball_radius ? BLUE : WHITE);
        setCursor(1, 100);
        sprintf(buf, "Ball Radius: %d", ball_radius);
        writeString(buf);

        // 7. Per-core timing from the previous frame (slower core in red)
        uint32_t phys = physics_us;
        setTextColor(phys > draw_us ? RED : WHITE);
        setCursor(1, 120);
        sprintf(buf, "Physics (core 1): %lu us", (unsigned long)phys);
        writeString(buf);

        setTextColor(draw_us >= phys ? RED : WHITE);
        setCursor(1, 130);
        sprintf(buf, "Draw (core 0): %lu us", (unsigned long)draw_us);
        writeString(buf);

        setTextColor(missed ? RED : WHITE);
        setCursor(1, 140);
        sprintf(buf, "Frame: %lu / 16667 us", (unsigned long)frame_us);
        writeString(buf);

        // 8. Core 0 draw time per stage. Clear, pegs and histogram are from
        // this frame; text and balls haven't finished yet, so they're from
        // the previous frame
        setTextColor(WHITE);
        setCursor(1, 155);
        sprintf(buf, "  Clear:     %lu us", (unsigned long)clear_us);
        writeString(buf);
        setCursor(1, 165);
        sprintf(buf, "  Pegs:      %lu us", (unsigned long)pegs_us);
        writeString(buf);
        setCursor(1, 175);
        sprintf(buf, "  Histogram: %lu us", (unsigned long)hist_us);
        writeString(buf);
        setCursor(1, 185);
        sprintf(buf, "  Text:      %lu us", (unsigned long)text_us);
        writeString(buf);
        setCursor(1, 195);
        sprintf(buf, "  Balls:     %lu us", (unsigned long)balls_us);
        writeString(buf);
        text_us = time_us_32() - mark;

        mark = time_us_32();
        for (int i = 0; i < num_balls; i++) {
            drawCircle(fix2int15(ball[i].x), fix2int15(ball[i].y), ball_radius, color);
        }
        balls_us = time_us_32() - mark;

        draw_us = time_us_32() - start;

        PT_SEM_SDK_WAIT(pt, &sem_physics_done);

        frame_us = time_us_32() - start;
        missed = frame_us > 16667;

        gpio_put(LED_PIN, missed);
        
    }

    PT_END(pt);
}



struct timespec initial_time = {
    .tv_sec = 0,
    .tv_nsec = 0,
};



int main() {
    //overclocking to 200 MHz
    set_sys_clock_khz(200000, true);
    stdio_init_all();
    initVGA();
    init_dma_chirp();


    aon_timer_start(&initial_time);



    int peg_index = 0;
    for (int row = 0; row < 16; row++) {
        for (int column = 0; column <= row; column++) {
            int x = 320 + (2 * column - row) * 19;
            int y = 100 + row * 19;
            peg[peg_index].x = int2fix15(x);
            peg[peg_index].y = int2fix15(y);
            peg_index++;
        }
    }

    gpio_init(ENC_A);
    gpio_init(ENC_B);
    gpio_set_dir(ENC_A, GPIO_IN);
    gpio_set_dir(ENC_B, GPIO_IN);
    gpio_pull_up(ENC_A);
    gpio_pull_up(ENC_B);

    gpio_init(LED_PIN);
    gpio_set_dir(LED_PIN, GPIO_OUT);

    gpio_init(LED_PIN);
    gpio_set_dir(LED_PIN, GPIO_OUT);


    gpio_init(PUSHBUTTON);
    gpio_set_dir(PUSHBUTTON, GPIO_IN);
    gpio_pull_up(PUSHBUTTON);

    gpio_set_irq_enabled_with_callback(ENC_A,
        GPIO_IRQ_EDGE_FALL, true, &gpio_callback);
    gpio_set_irq_enabled(PUSHBUTTON,
        GPIO_IRQ_EDGE_FALL, true);

    sem_init(&sem_physics_start, 0, 1);
    sem_init(&sem_physics_done, 0, 1);
    multicore_reset_core1();
    multicore_launch_core1(core1_main);

    pt_add_thread(protothread_anim);

    pt_schedule_start;

    return 0;
}
```
]

== VGA RGB Output (`rgb.pio`)

#block(
  width: 100%,
  breakable: true,
  fill: rgb("#f5f5f5"),
  stroke: 0.5pt + rgb("#dddddd"),
  radius: 3pt,
  inset: 10pt,
)[
#set text(size: 8pt)
#set par(justify: false, leading: 0.45em)
#set raw(tab-size: 4)
```
;
; Hunter Adams (vha3@cornell.edu)
; RGB generation for VGA driver
; mod by Bruce Land for 16 colors
; Packed 1-bit framebuffer output as black or white

; Program name
.program rgb
.define PUBLIC vid_freq 200

.wrap_target

mov x, isr [1]           ; Reload 639; finish the last pixel before blanking
set pins, 0 				; Zero RGB pins in blanking
wait 1 irq 1 [3]         ; Align the first color SET with active video

; AI-written code

colorout:
    out y, 1             ; Extract one bit; autopull reloads OSR after eight bits
    jmp !y black         ; if bit is 0, we know the color is black

    set pins, 15 [3]     ; if bit is 1, the color is white, set the pins high for 4 clock cycles to transmit 1111
    jmp nextpixel

black:
    set pins, 0 [4]      ; set pin low for 4 cycles for black

nextpixel:
    jmp x-- colorout     ; Same counter register as original

.wrap

% c-sdk {
static inline void rgb_program_init(PIO pio, uint sm, uint offset, uint pin) {

    // creates state machine configuration object c, sets
    // to default configurations. I believe this function is auto-generated
    // and gets a name of <program name>_program_get_default_config
    // Yes, page 40 of SDK guide
    pio_sm_config c = rgb_program_get_default_config(offset);

    // Map the state machine's SET and OUT pin group to four pins, the `pin`
    // parameter to this function is the lowest one. These groups overlap.
    sm_config_set_set_pins(&c, pin, 4);
    sm_config_set_out_pins(&c, pin, 4);

    // Set clock division (Commented out, this one runs at full speed)
    // sm_config_set_clkdiv(&c, 5) ;

    // longer FIFO to avoid bursty data
    sm_config_set_fifo_join (&c, PIO_FIFO_JOIN_TX) ;

    // Set this pin's GPIO function (connect PIO to the pad)
    pio_gpio_init(pio, pin);
    pio_gpio_init(pio, pin+1);
    pio_gpio_init(pio, pin+2);
    pio_gpio_init(pio, pin+3);
    
    // Set the pin direction to output at the PIO (4 pins)
    pio_sm_set_consecutive_pindirs(pio, sm, pin, 4, true);

    // Initialize the saved row count while autopull is disabled.
    sm_config_set_out_shift(&c, true, false, 8);
    pio_sm_init(pio, sm, offset, &c);
    pio_sm_put_blocking(pio, sm, 639);
    pio_sm_exec(pio, sm, pio_encode_pull(false, true));
    pio_sm_exec(pio, sm, pio_encode_out(pio_isr, 32));

    // Shift pixels lowest-bit first; fetch a new FIFO word every eight bits.
    sm_config_set_out_shift(&c, true, true, 8);
    pio_sm_set_config(pio, sm, &c);

    // Set the state machine running (commented out, I'll start this in the C)
    // pio_sm_set_enabled(pio, sm, true);
}
%}
```
]

// ============================================================
#heading(numbering: none)[Appendix B --- AI Prompt Log]
// ============================================================
#todo[For each prompt: time, what was asked, edits suggested, and edits accepted.]
