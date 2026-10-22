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

// Appendix B prompt log helpers
#let prompt(n, body) = block(
  width: 100%,
  inset: (x: 10pt, y: 8pt),
  radius: 3pt,
  fill: rgb("#eef4fb"),
  stroke: (left: 2.5pt + rgb("#2563eb")),
  breakable: true,
)[
  #text(size: 9pt, weight: "bold", fill: rgb("#2563eb"))[Prompt #n]
  #v(0.2em)
  #body
]
#let reply(body) = block(
  width: 100%,
  inset: (left: 10pt, y: 4pt),
  stroke: (left: 1pt + luma(190)),
  breakable: true,
)[#body]
#let ide-note(body) = text(size: 9pt, style: "italic", fill: luma(90))[#body]

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
    [Overclock], [System clock raised from 150 MHz to 200 MHz], [19,000],
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

*Things we tried and undid.* 
- Stochastic rounding: Stochastic rounding is strategy for removing systemic error in rounding from data by randomly rounding up or down. The idea is that the expectation value of a uniform random distribution is exactly the mean of the distribution, which is not true for rounding a fixed precision decimal up. We tried doing this because our distribution was shifted very slightly, and we hypothesized this was the issue. In fact, the real issue was just that our histogram bins were not aligned with respect to the bottom row of pegs. 

- Separate protothreads for the text and the histogram: When we moved to a multicore system, we ran the entire graphics thread on a single core as part of one thread. One idea we had to speed up runtime was to draw the histogram bins and text at a lower rate (20 FPS, as opposed to 60), to free up time for the graphics thread. While this did lower the frequency at which we missed timing for the same number of balls, we were not able to actually draw more balls on the screen, as on certain threads all three threads would have to run (balls & pegs, text, histogram). Additionally, the switching seemed to add overhead, as the total graphics runtime was longer for this approach. 

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

Visually, the galton board seemed to be accurate and result in the expected Gaussian distribution. Although, we assume that using fixed point instead of floating point would likely have caused some rounding errors & loss in precision. 

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

#show raw.where(block: true): set text(size: 8pt)

#prompt(1)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

can you take a look at the way i use semaphores for the concurrent draw and animate threads? i know waiting for physics after drawing the balls is sus, but i can tolerate drawing a ball in the wrong / previous frame position once, so long as it doesn't create any actual code bugs. Primarily i want to maximize parallelism / time for my physics and animation threads to run
]

#reply[
Your current scheme has no correctness bugs. It also gives you less overlap between the cores than you probably think.

What the current code does

Each frame on core 0 runs: wait for vsync → clear → draw pegs → release start → draw histogram/UI → wait for done → draw balls.

So the only overlap is physics against the histogram/UI drawing. Core 1 sits idle during the clear, the peg drawing, and the ball drawing, and drawing \~470 balls is likely your most expensive draw step. Core 0 also stalls whenever physics takes longer than the UI. Because core 1 never runs while core 0 reads ball\[\], the ball positions are race-free, but the design is close to serial.

Suggested change: snapshot positions, then run physics for the whole frame

Copy the positions out right after physics finishes, then start the next physics step immediately. Core 1 then gets roughly the full 16.6 ms, and core 0 draws the whole frame from the snapshot. The cost is one frame of display lag, which you said is fine. The snapshot is always self-consistent, so you never get a half-updated ball.

```
static fix15 draw_x[MAX_NUM_BALLS], draw_y[MAX_NUM_BALLS];
static int draw_hist[NUM_BINS];
static int n, r;
```

```
while (1) {
    PT_YIELD_UNTIL(pt, draw_start_signal());
    uint32_t start = time_us_32();
```

```
    // Wait for physics step N, snapshot it, then start step N+1 right away
    PT_SEM_SDK_WAIT(pt, &sem_physics_done);
    n = num_balls;
    r = ball_radius;
    for (int i = 0; i < n; i++) { draw_x[i] = ball[i].x; draw_y[i] =
ball[i].y; }
    memcpy(draw_hist, histogram, sizeof(draw_hist));
    sem_release(&sem_physics_start);
```

```
clearLowFrame(0, BLACK);
// pegs, draw_histogram(draw_hist), UI text ... (unchanged)
for (int i = 0; i < n; i++)
    fillCircle(fix2int15(draw_x[i]), fix2int15(draw_y[i]), r, color);
```

```
    missed = time_us_32() - start > 16667;
    gpio_put(LED_PIN, missed);
}
```

You also need to change the init so the first frame doesn't block forever:

```
sem_init(&sem_physics_start, 0, 1);
sem_init(&sem_physics_done, 1, 1);   // "step 0" (spawn positions) is ready
```

This is safe because core 1 only touches ball\[\] after it acquires start. Your spawn loop at the top of protothread\_anim therefore finishes first. The copy is about 470 × 8 bytes, a few microseconds. The missed LED now also catches the case where physics alone runs past 16.6 ms, which is the deadline you actually care about.

Smaller things worth knowing

- Histogram tearing (already happens today): draw\_histogram runs while core 1 is doing histogram\[bin\]++. normalize\_histogram reads each bin twice, once for the max and once for the height. If a bin grows in between, its bar can come out slightly taller than HIST\_HEIGHT. It's only a visual glitch, and the draw\_hist snapshot above fixes it.
- Cross-core reset race: gpio\_callback runs on core 0 and does reset\_histogram() and fallen\_balls = 0 while core 1 may be in the middle of a ++ on the same value. That's a non-atomic read-modify-write across cores, so a reset can occasionally get lost and leave a stale count. If you care, have the interrupt set a volatile bool reset\_req and let core 1 clear the values at the top of its loop.
- num\_balls / ball\_radius changing mid-step: This is harmless. Arrays are sized to MAX\_NUM\_BALLS and drawPixel clips, so it can't index out of bounds or write outside the framebuffer.
- Unrelated bug: the gravity clamp at encoder.c:212-213 (encoder.c\#L212-L213) is inside the \_ball\_radius branch instead of the \_GRAVITY branch. Gravity can therefore go negative or grow without limit while you're adjusting it.

Want me to apply the snapshot change?
]

#prompt(2)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

my performance improves alot moving the SEM\_SDK\_WAIT in the animation till after the ball drawing step. is that fine? ideally i don't want to duplicate positions in memory because that will limit the number of balls i can render
]

#reply[
Yes, that's fine. Drawing the balls while core 1 is still updating them causes visual glitches only, not memory or logic bugs, and it needs no second copy of the positions. Here's why it's safe, plus one small change that gets you a bit more overlap.

What can actually happen

Core 0 now reads ball\[i\].x and ball\[i\].y while core 1 may be writing them. The worst cases:

- Mixed steps: a ball is drawn with this step's x and last step's y, or the reverse. Each field is an aligned 32-bit word, so a read always gets either the old or the new value, never a corrupted one. That means at most one physics step of error, which is about a pixel or two.
- A position caught partway through an update:
  - Between b-\>y += b-\>vy and the respawn in updateBallPhysics, y can briefly be past 480. fillCircle rejects anything where y0 + r \> 479 (vga16\_graphics\_v3.c:615 (VGA/vga16\_graphics\_v3.c\#L615)), so that ball just isn't drawn that frame.
  - During a collision teleport, x may already be updated while y isn't yet, so the ball is drawn slightly off for one frame.
- num\_balls or ball\_radius changing mid-frame: harmless, since every index stays below MAX\_NUM\_BALLS.

One thing that could become a real bug if you change the board layout: fillCircle checks y but not x, and drawHLine doesn't reject negative x. A ball with x0 - r \< 0 would write before the start of its row, and on row 0 that's before the start of the framebuffer. You're safe now because the walls clamp x to at least 35 + ball\_radius, and even mid-update positions stay far above r. Just don't move the walls near x = 0 without adding a clamp.

The handshake itself is correct. Both semaphores start at 0 with a max of 1, so each frame does exactly one release-start and one wait-done, and the two cores can never drift by more than one step.

A bit more parallelism for free

Release sem\_physics\_start before clearLowFrame instead of after it. The clear is a memset over the whole framebuffer, and it doesn't read ball\[\], so core 1 can start physics while it runs:

```
PT_YIELD_UNTIL(pt, draw_start_signal());
uint32_t start = time_us_32();
sem_release(&sem_physics_start);   // physics overlaps the clear too
clearLowFrame(0, BLACK);
```

Keep the PT\_SEM\_SDK\_WAIT at the bottom of the frame where you have it. That wait is what stops core 1 from starting another step while core 0 is in the next clear. It also means your missed LED measures the slower of physics and drawing, which is the deadline you care about.
]

#prompt(3)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

can you print to the VGA screen timers for both threads so i can see where the bottleneck is?
]

#reply[
PowerShell(ninja -C build 2\>&1 | Select-Object -Last 15)
]

#reply[
I added three timing lines to the VGA text panel, under "Ball Radius". The firmware builds cleanly with ninja. The editor's "uint32\_t is undefined" errors come from the editor's code analysis, not the compiler.

Physics (core 1): \_\_\_ us Draw (core 0):    \_\_\_ us Frame: \_\_\_ / 16667 us

- Physics is how long one physics step takes on core 1, from when it acquires sem\_physics\_start to just before it releases sem\_physics\_done. It's stored in a new global, volatile uint32\_t physics\_us.
- Draw is how long core 0 takes from the vsync signal to finishing the ball drawing, which is everything before it starts waiting for physics.
- Frame is how long core 0 takes from vsync until physics is done. This is the real frame time, and it should come out close to whichever of the other two is larger.

Whichever of Physics and Draw is slower shows in red, so the bottleneck is obvious at a glance. The Frame line turns red when you miss the 60 fps deadline, matching the LED. All three numbers are from the previous frame, because the text is drawn before the current frame's times are known.

I also fixed a bug: start was an ordinary local variable inside the protothread. Protothreads don't keep local variables across a yield, and PT\_SEM\_SDK\_WAIT yields whenever physics isn't finished yet. After the wait, start could hold garbage, so your old missed check and LED weren't reliable. start, draw\_us and frame\_us are now static.

When reading the numbers, keep in mind that both cores share memory and the framebuffer. Running them together can make each a little slower than it would be alone, so the two times won't add up exactly.
]

#prompt(4)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

check my fixed poiint square root and rewrite physics thread to use that rather than floating point square root. currently physics is at 16000 us with draw at 8500 us
]

#reply[
PowerShell(ninja -C build 2\>&1 | Select-Object -Last 15)
]

#reply[
Checking the new square root's accuracy with a quick Python simulation, since there's no host C compiler.
]

#reply[
I replaced your square root with a fixed-point version and switched the collision code to it, so it no longer uses any float math. It builds cleanly. I haven't run it on the board, and I don't expect it to noticeably lower your 16000 µs physics time.

Problems with your sqrt\_fx15

+ Divide by zero: for a raw input of 1, the first guess x \>\> 1 is 0, and divfix(x, 0) divides by zero.
+ Wrong for large inputs: starting from x/2, Newton's method spends its first iterations just halving. For large inputs, 10 iterations isn't enough. At the maximum value it's off by a lot, but it was fine for the distances you actually use.
+ Slow: each iteration does a 64-bit div\_s64s64. The Pico 2 (RP2350) has no hardware for 64-bit division, so 10 of them likely take hundreds to over a thousand cycles. The M33 core has a hardware float unit, so sqrtf is one instruction of about 14 cycles. Your version would have been slower than the float code it replaced.
+ The comment calls it "alpha-beta". It's actually Newton's method.

What I changed (encoder.c:255-292 (encoder.c\#L255-L292))

- sqrt\_fx15 now uses a digit-by-digit integer square root: only shifts, adds and compares, no division. In a Python simulation of the same algorithm it was within 1 LSB of the exact answer across the input range (e.g. √2 → 1.41418, √512 → 22.6274).
- The collision check compares squared distances (dist\_sq \< col\_dist²). The square root only runs on an actual hit, not on every ball that passes the bounding-box test.
- Normalizing the collision direction uses one division: it computes 1/distance once and multiplies dx and dy by it. Before, it divided each separately.
- The |dx| \< 0.5 nudge is now in fixed point too.

Why physics will still take about 16 ms

The square root only runs for the few balls that are touching a peg in a given frame. The real cost is the loop itself: 136 pegs × 470 balls is about 64,000 calls to checkBallCollision per step. Each call re-reads the volatile ball\_radius and does the bounding-box test, and almost all of them miss. At 150 MHz, 16 ms works out to roughly 37 cycles per check, which fits that loop rather than the square root.

The fix that would actually help is to stop testing every peg against every ball. The pegs sit on a regular grid, 19 px apart vertically and 38 px apart within a row. From a ball's position you can compute which row and column it's nearest. Then you only check that peg and its immediate neighbours, about 3 checks per ball instead of 136. That should cut the collision work by more than 40×. Separately, reading ball\_radius into a local once per step would make every remaining check a little cheaper.

Want me to implement the grid lookup?
]

#prompt(5)[
can you do alphamax betamin. I can tolerate a pretty large error here. do alpha = 1 and beta = 1/2
]

#reply[
PowerShell(ninja -C build 2\>&1 | Select-Object -Last 15)
]

#reply[
I swapped the square root for alpha-max-beta-min with α = 1 and β = ½. It builds cleanly, but I haven't run it on the board.

The distance is now estimated as max(|dx|, |dy|) + min(|dx|, |dy|) / 2, which is two absolute values, a compare, a shift and an add. It's in a small inline helper, dist\_amax\_bmin, in encoder.c:255-262 (encoder.c\#L255-L262). I removed sqrt\_fx15 because nothing calls it anymore. The squared-distance check is gone too, so the collision test now uses the estimate directly. The one remaining divide computes 1/distance for the collision direction.

What the error does in practice:

- It only ever overestimates. The estimate is exact when the ball is directly above, below or beside a peg. It's about 6% high on a diagonal and at most about 11.8% high when one offset is half the other. So in those directions a hit only registers once the ball is up to about 12% closer than ball\_radius
  - PEG\_RADIUS, roughly 1–2 px. It never registers a hit that isn't really there.
- The teleport stays consistent. Because the direction vector comes out a little short, the ball gets pushed out a bit less than the full collision distance. But the estimate overshoots by the same factor at that new spot, so the ball reads as exactly at the collision distance. It won't immediately collide with the same peg again on the next step.
- Bounces are slightly softer. The short direction vector under-reflects the velocity by up to about 20% in the worst direction. Your bounciness scaling and random kick will mostly hide that.

As I mentioned last time, this mostly helps when a ball is near a peg. The 136 × 470 bounding-box loop is still where most of the 16 ms goes, so check the Physics timer on screen to see how much this actually saves.
]

#prompt(6)[
#ide-note[IDE context.]

make a special case for drawCircle function for radius = 1 that hardcodes the result rather than calculating pixel values.
]

#reply[
For radius 1, the Bresenham loop ends up redrawing the same 4 pixels forming a plus shape, making 12 drawPixel calls total, while the fast path simply draws those 4 pixels directly and returns.
]

#reply[
PowerShell(ninja -C build 2\>&1 | Select-Object -Last 15)
]

#reply[
drawCircle now has a special case for radius 1 that draws 4 hardcoded pixels and returns: vga16\_graphics\_v3.c:524-532 (VGA/vga16\_graphics\_v3.c\#L524-L532). The firmware builds cleanly; I haven't run it on the board.

I traced the general algorithm by hand for r = 1. It draws only the four pixels directly above, below, left and right of the center (a plus shape with no center pixel). It makes 12 drawPixel calls to do it, because its loop runs once and redraws each of those pixels twice. The special case draws exactly the same 4 pixels, so the picture won't change. It just skips the setup and the 8 duplicate calls.

It still goes through drawPixel, so balls at the edge of the screen are still clipped safely. Writing straight into the framebuffer would be a little faster, but you'd have to redo that bounds check yourself.
]

#prompt(7)[
minimal change: instead of random impulse on a bounce can we vary the starting ball spawn position by a couple of pixels
]

#reply[
PowerShell(ninja -C build 2\>&1 | Select-Object -Last 15)
]

#reply[
Balls now spawn at a random spot within about 2 px of center instead of exactly at x = 320, and I removed the random ±0.2 sideways kick on each bounce. The firmware builds cleanly; I haven't run it on the board.

- Spawn: encoder.c:249-250 (encoder.c\#L249-L250) now sets b-\>x = int2fix15(318) + (rand() & 0x1FFFF). In fix15, 0x1FFFF is just under 4 px, so x lands between 318 and 322 px, at sub-pixel precision.
- Bounce: the two impulse lines are gone from checkBallCollision.

Bounces are now completely determined by where the ball spawned, so all the spread comes from that starting offset. Each peg collision should magnify small differences, but check that the histogram still looks bell-shaped. If balls cluster in a few bins, widen the spawn range: use int2fix15(316) + (rand() & 0x3FFFF) for ±4 px.

The one remaining rand() in the collision code is the nudge for a ball landing almost exactly on top of a peg (|dx| \< 0.5). I left it in, because without it that ball would bounce straight up and land on the same peg again.
]

#prompt(8)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

this change totally broke the screen, why would that happen?
]

#reply[
Checking memory and whether rand() pulls in heap allocation.
]

#reply[
The linked rand() is newlib's full version using static state, not heap allocation, so it's not the crash source. Now I'll simulate the physics in Python, comparing old and new versions, to see what changes on screen.
]

#reply[
The simulation reproduces it: with the new spawn, almost every ball falls straight down the center. I'll check whether a much wider spawn range fixes it before answering.
]

#reply[
The spawn change didn't break anything in the code. It changed the physics: without the random kick on each bounce, nearly every ball now falls straight down the center column. I'm assuming that's the broken screen you're seeing. If instead the display is showing garbage or has frozen, tell me, because that would be a different problem.

Simulation results. I ported your current physics to Python and ran 600 balls for 900 frames. Histogram counts by bin:

```
┌─────────────────────────────────────────┬────────────────────────┐
│                 Version                 │       Bins 6–10        │
├─────────────────────────────────────────┼────────────────────────┤
│ Old: spawn at 320, ±0.2 kick per bounce │ 19, 550, 1334, 527, 13 │
├─────────────────────────────────────────┼────────────────────────┤
│ New: ±2 px spawn, no kick               │ 0, 32, 2482, 27, 0     │
├─────────────────────────────────────────┼────────────────────────┤
│ New with ±8 px spawn                    │ 0, 459, 1701, 509, 0   │
└─────────────────────────────────────────┴────────────────────────┘
```

In the new version about 98% of balls land in the middle bin. The simulation also shows many balls stuck bouncing near the top peg.

- Why this happens:
- Every bounce shrinks the differences between balls. With bounciness at 0.3, a collision throws away 70% of the ball's speed. Two balls that arrive a pixel apart leave the peg with almost the same small sideways speed, so the ±2 px spawn spread gets damped at the first peg instead of amplified.
- The center column funnels them. The pegs straight below 320 are at rows 0, 2, 4 and so on, with a gap at x = 320 in each row between them. A ball with almost no sideways speed drops through the gap and hits the next center peg nearly dead-on. That triggers the |dx| \< 0.5 nudge, which only moves it 2 px. So it never drifts a full peg spacing (19 px) to the side.
- The kick was what spread the balls out. A random ±0.2 px/frame on every bounce is a fresh coin flip at each peg, which is what gives you a bell curve. With it gone, a ball's path is fixed by where it spawned, and the damping erases that.

A wider spawn range doesn't fix it. The ±8 px run above still puts two-thirds of the balls in the middle bin.

Fix: put the random kick back. The simplest way is git revert fb98f5c. If you want to keep the spawn spread too, just re-add the two impulse lines after the bounciness scaling in checkBallCollision. Spawn spread alone can't give you the spread, because the physics doesn't amplify small differences. Want me to restore it?
]

#prompt(9)[
no, the display is showing garbage right now
]

#reply[
Since the VGA buffer swaps on a fixed DMA timer regardless of whether drawing finished, frames exceeding 16.7ms could cause visual glitches. I'll verify whether the new spawn significantly slows physics by counting collisions per frame.
]

#reply[
I think the garbage comes from frames taking longer than 16.7 ms, not from anything in the spawn code. The likely culprit is an earlier commit, not the spawn change. I haven't seen it on the hardware, so the first step below is a quick test.

How an overrun turns into garbage. The VGA library swaps buffers on its own. A DMA chain rewrites current\_draw\_buffer every vsync, whether or not core 0 has finished drawing (vga16\_graphics\_v3.c:289-300 (VGA/vga16\_graphics\_v3.c\#L289-L300)). Nothing waits for the frame to finish. If a frame overruns, core 0 keeps drawing after the swap, but now into the buffer that's on screen. The next frame's clearLowFrame can then wipe the displayed buffer partway through the scan. You get torn, half-cleared, flickering frames.

Why I don't think the spawn change is the main cause. I counted peg collisions per frame in the Python simulation from earlier: about 104 in the old version and 141 in the new one. That's about 35% more collisions, but they're a small part of physics time. It shouldn't be enough to push a working frame past the deadline on its own.

The likelier cause is in the commit before it. 23abb41, labeled "readability changes", also changed two constants:

```
-#define MAX_NUM_BALLS 5000
-volatile int num_balls = 470;
+#define MAX_NUM_BALLS 10000
+volatile int num_balls = 5000;
```

You measured draw at about 8.5 ms with 470 balls. Starting with 5000 balls is more than 10× the ball drawing and ball physics. That almost certainly blows the 16.7 ms frame from the very first frame. If you went from f1d696d straight to the spawn change, this came along with it.

Quick test: set num\_balls back to 470 and reflash. If the display comes back, step the encoder up and watch the Physics and Draw readouts. Garbage should start right around where Frame passes 16667 µs. Your missed-frame LED should already be on solid right now.

- Fixes, depending on what you want:
- Keep the default ball count low and raise it with the encoder, staying under whatever count holds 60 fps.
- Switch the library to DOUBLE\_BUFFER\_30 (vga16\_graphics\_v3.c:85 (VGA/vga16\_graphics\_v3.c\#L85)) if you'd rather run more balls at 30 fps. That gives each frame about 33 ms.
- Put the random kick back as discussed earlier. It fixes the balls bunching down the center, and it also removes the extra collisions, which you'd otherwise pay for on every frame.
]

#prompt(10)[
can you re-apply the change
]

#reply[
I re-applied the spawn change. encoder.c now matches fb98f5c exactly, and the firmware builds; I haven't flashed it.

- spawnBall again sets x to int2fix15(318) + (rand() & 0x1FFFF), a random start between 318 and 322 px.
- The ±0.2 random kick on each bounce is removed again.

It isn't committed; it's only in your working tree.

num\_balls still starts at 5000, so if you were getting garbage before re-applying this, you'll still get it. Lower that default to fix it. Also, from the simulation, expect most balls to fall down the center column with this change, since there's no longer a random kick at each peg to spread them out.
]

#prompt(11)[
```
<ide_selection>The user selected the lines 261 to 265 from
c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c:
    // stochastic rounding
    if ((rand() & 0x7FFF) < (absfix15(dx) + absfix15(dy)) & 0x7FFF) {
        val++;
    }
```

This may or may not be related to the current task.\</ide\_selection\>
]

#prompt(12)[
explain what the stochastic rounding thing i added at 261 through 264 to make the distribution nicer does at a bit level
]

#reply[
As written, this line almost never does anything random. It adds exactly 1 LSB to val on essentially every call. That's 1/32768 of a pixel, far too small to change where balls land.

What the line actually does

```
if ((rand() & 0x7FFF) < (absfix15(dx) + absfix15(dy)) & 0x7FFF) {
```

+ Operator precedence. In C, \< binds tighter than &, so the compiler reads the line as:

```
if ( ((rand() & 0x7FFF) < (ax + ay)) & 0x7FFF )
```

The comparison gives 0 or 1, and & 0x7FFF leaves 0 or 1 unchanged. So the trailing mask does nothing, and the test is just if ((rand() & 0x7FFF) \< ax + ay).

+ The left side is rand() & 0x7FFF. It keeps the low 15 bits of rand(), giving a uniform random integer from 0 to 32767. In fix15, that's a random number from 0.0 up to just under 1.0 pixel.

+ The right side is ax + ay, the full fix15 value, not just its fractional bits. It only gets here after the bounding-box test, so |dx| and |dy| are up to 16 px each. During an actual collision the ball is about 10 px from the peg, so ax + ay is roughly 327,680 or more in raw units. That's well above 32,767 whenever ax + ay is at least 1 px.

+ So the comparison is effectively always true. The random number is always under 1.0 px, and ax + ay is always well over it. The only random case is a ball within 1 px of a peg's exact center in both x and y.

+ val++ adds one raw LSB, which is 2⁻¹⁵ px, about 0.00003 px.

I checked this in the Python simulation (600 balls, 900 frames). The increment fired on 341,002 of 341,002 calls. The histogram was unchanged: 2,477 of the balls in the center bin, against 2,482 without the line. If the board looks better to you, I'd suspect something else is different, such as a different ball count or bounciness. The simulation may also not match your hardware exactly, so it's worth a direct A/B test.

What it was probably meant to be, and why that still wouldn't help

With parentheses, (rand() & 0x7FFF) \< ((ax + ay) & 0x7FFF) is real stochastic rounding. It compares a random 15-bit number against the 15 fractional bits of ax + ay. It would round up with probability equal to that fractional part, so on average the value is unbiased. Two problems remain:

- Those aren't the bits that get thrown away. The only precision dist\_amax\_bmin loses is the one bit shifted out by min \>\> 1. Stochastic rounding of that would be val += (min & 1) & rand();.
- Either way, the nudge is 1 LSB. Randomness that small gets washed out at the first bounce, the same reason the ±2 px spawn spread didn't help. To actually spread the balls, the randomness has to be about pixel-sized: a sideways speed change per bounce, like the old ±0.2 px/frame impulse.
]

#prompt(13)[
i am trying to fix the histogram distribution, which currently is more spread out on the left, and more condensed on the right. my hypothesis was systemic error from rounding at this stage. if this won't work, revert it and see what else we can do
]

#reply[
I'll remove the stochastic rounding first, then measure where balls actually land compared with the bin edges.
]

#reply[
The simulation looks roughly symmetric (mean landing x ≈ 319.6, 2898 left vs 2820 right of 320), but the bins aren't centered on 320. I'll check the simulation fix before making edits.
]

#reply[
With the bins re-centered on 320, the simulated histogram comes out symmetric. I'll apply that.
]

#reply[
Rounding wasn't the cause. The asymmetry comes from where the histogram bins sit: they weren't centered on the board. I removed the stochastic rounding and re-centered the bins. It builds; I haven't run it on the board.

What was wrong

The old binning was bin = x\_pixel / BIN\_WIDTH, so bin 0 started at x = 0 and the middle bin (8) spanned x = 304–341. Its center was 323, not 320, so every bin edge sat 3 px to the right of where it should be relative to the pegs.

Balls leave the bottom row in clusters centered on the gaps between pegs (320, 320 ± 38, …). With every edge shifted right:

- The edge on the left side of each cluster cuts into the cluster, so some balls spill into the bin further left.
- On the right side, the edge sits in empty space past the cluster, so nothing spills right.

That produces exactly what you saw: wider on the left, tighter on the right.

Evidence from the simulation

I used the version with the random kick, since that's the one that actually spreads balls out. 5718 balls landed. Counts in bins 6 to 10:

```
┌──────────────────┬──────────────────────────┐
│                  │        Bins 6–10         │
├──────────────────┼──────────────────────────┤
│ Old bins         │ 46, 1266, 3175, 1210, 20 │
├──────────────────┼──────────────────────────┤
│ Re-centered bins │ 23, 1192, 3225, 1250, 25 │
└──────────────────┴──────────────────────────┘
```

The landing positions themselves were nearly symmetric: mean x = 319.6, with 2898 balls left of 320 and 2820 right. The 0.4 px leftward lean is about the size of random noise at this ball count. Bit-level rounding could only ever cause a bias about that small, too small to matter next to 38 px bins.

The fix

- HIST\_LEFT is now the left edge of bin 0: 320 - BIN\_WIDTH/2 - (NUM\_BINS/2)\*BIN\_WIDTH, which is −3. The middle bin now spans x = 301–339, centered on 320, and every bin edge lines up with a bottom-row peg.
- The binning and the drawing now use the same origin. Binning is bin = (x\_pixel - HIST\_LEFT) / BIN\_WIDTH. The bars were already drawn from HIST\_LEFT, so they now match the bins exactly. Before, the drawing used −2 and the binning used 0.

Bins 0 and 16 lie outside the walls at x = 35 and 605, so they'll always stay empty. You could drop to 15 bins later.

Your current code still has no random kick, so most balls will still fall down the center as before. The histogram now records them accurately, but to see a real bell curve you still need that kick back.
]

#prompt(14)[
instead of clearing the whole screen, clear just the text, histogram, and draw black balls on the previous ball position to clear them. we are at 1b color now.
]

#reply[
I haven't made this change. Two things make it a bad trade with the current setup, and the first one needs a decision from you.

+ With double buffering, the erase needs two saved copies of every ball position

The library runs with DOUBLE\_BUFFER\_60, so frames alternate between vga\_buffer\_0 and vga\_buffer\_1. The buffer you draw into in frame N last held frame N−2, not the previous frame. To erase correctly, you'd have to keep the positions you drew for each buffer separately, as two arrays. The current ball positions don't help: by draw time, physics has already moved them, and collisions and respawns teleport balls, so you can't work backwards.

At MAX\_NUM\_BALLS = 10000, two arrays of 16-bit x and y take 2 × 10000 × 4 bytes = 80 KB. The build currently uses about 475 KB of the 512 KB of RAM (.bss 471 KB plus .data 4 KB), leaving roughly 49 KB. It doesn't fit. Packing tighter doesn't save enough: a pixel position needs 19 bits, so even 3 bytes per ball comes to 60 KB. To make it fit, you'd have to cut MAX\_NUM\_BALLS to about 6000, which is the limit on ball count you said earlier you wanted to avoid.

+ It would probably make drawing slower, not faster

clearLowFrame is a single memset of 150 KB. By my estimate, that's about 40k cycles, roughly 0.3 ms at 150 MHz. That's a small slice of the 16.7 ms frame, and I haven't measured it on the board.

Erasing a ball with a black drawCircle costs exactly as much as drawing it. At radius 4 that's about 28 drawPixel calls. With thousands of balls, ball drawing is already most of your Draw time, so erasing this way roughly doubles it.

You'd also need to redraw the pegs every frame, because erasing a ball near a peg cuts holes in it. You'd draw the new balls only after all the erases, so that one ball's erase doesn't cut into another ball.

Overall this approach only pays off when the clear costs more than drawing the balls, so with few balls or a 1-pixel radius.

Options

- Measure first. Put a time\_us\_32() around clearLowFrame and show it on screen. If it's well under 1 ms, the clear isn't your bottleneck and this change can't help much.
- If you really mean 1-bit color at the library level, make the framebuffer 1 bit per pixel. Right now the library is still 4 bits per pixel, and your UI text uses BLUE and RED. A 1-bit buffer cuts the clear to about 38 KB and makes each ball cheaper to draw. That speeds up the existing approach without storing any extra positions. It's a bigger change: the rgb.pio program, the DMA transfer size, and drawPixel all change.
- Erase anyway, with a smaller ball limit. I can implement it with two position arrays and MAX\_NUM\_BALLS reduced to about 6000, then compare the Draw timer before and after.

Which do you want?
]

#prompt(15)[
pulled the 1b color change. can you instead just add timers that show how long i spend: drawing text drawing balls drawing pegs drawing histogram
]

#reply[
PowerShell(ninja -C build 2\>&1 | Select-Object -Last 5)
]

#reply[
I added on-screen timers for each drawing stage. They sit under the existing Physics / Draw / Frame lines. The firmware builds; I haven't run it on the board.

Clear:     \_\_\_ us Pegs:      \_\_\_ us Histogram: \_\_\_ us Text:      \_\_\_ us Balls:     \_\_\_ us

- Clear: I added this one beyond your four, because it answers the open question from last time: whether wiping the whole screen each frame is actually expensive.
- Pegs: the 136 peg circles.
- Histogram: draw\_histogram, which covers the bars plus the count printed above each bin.
- Text: every text line, including these timer lines themselves.
- Balls: the ball drawing loop.

Clear, Pegs and Histogram show this frame's times. Text and Balls haven't finished when the text is printed, so they show the previous frame's times, which is fine for spotting the bottleneck.

The five should add up to roughly the "Draw (core 0)" line. The difference is the sem\_release call and the timer reads themselves, which take a few microseconds.

The editor's red "undefined identifier" errors are from its code analysis, not the compiler. They also appear on code that hasn't changed.
]

#prompt(16)[
ok we spend 2k us writing text. can we optimize for text to only redraw if the text changes? we can move the histogram number labels to be at the bottom of the screen instead of on top of the histogram bar so we can make the same optimization. our clear screen then should not clear the text and histogram area. also move the top left ui text and histogram rendering into seperate threads that render at 20 Hz
]

#reply[
This is a sizable change. Before writing code I'm checking the font format, the thread limit, and the screen geometry.
]

#reply[
Since the font is static and DMA overwrites current\_draw\_buffer each vsync, I'll add small library helpers that accept an explicit buffer pointer so text can be drawn into both buffers.
]

#reply[
Now replacing the old histogram drawing with a 20 Hz histogram thread, and adding the 20 Hz text thread.
]

#reply[
Removing the old physics\_us definition that's now duplicated, then rewriting the animation thread.
]

#reply[
The build passes. Next I'm checking that the file's line endings are still consistent, and looking for warnings in the code I changed.
]

#reply[
The text and histogram now each run in their own 20 Hz thread, redraw only what changed, and the per-frame clear leaves both areas alone. It builds with no new warnings, but I haven't run it on the board.

New screen layout:

```
┌─────────────────────────────────┬─────────┬────────────────────────────┐
│              Area               │  Rows   │        Who draws it        │
│                                 │   (y)   │                            │
├─────────────────────────────────┼─────────┼────────────────────────────┤
│ UI text box, x 0–167            │ 50–203  │ Text thread at 20 Hz, only │
│                                 │         │  lines that changed        │
├─────────────────────────────────┼─────────┼────────────────────────────┤
│ Histogram: bars, with count     │         │ Histogram thread at 20 Hz, │
│ labels on the bottom row (y     │ 392–479 │  only bins that changed    │
│ 472)                            │         │                            │
├─────────────────────────────────┼─────────┼────────────────────────────┤
│ Everything else                 │ —       │ Animation thread: clear,   │
│                                 │         │ pegs, balls every frame    │
└─────────────────────────────────┴─────────┴────────────────────────────┘
```

Changes that matter:

- Static content goes into both buffers. With double buffering, text drawn into only one buffer would flicker on and off every other frame. Pointing current\_draw\_buffer at each buffer in turn isn't safe, because the DMA rewrites it on every vsync. So I added three helpers to the VGA library that take an explicit buffer: drawStringBuffer, fillRectBuffer and drawRectBuffer. They're in vga16\_graphics\_v3.c (VGA/vga16\_graphics\_v3.c), declared in the header. The text and histogram threads draw into vga\_buffer\_0 and vga\_buffer\_1 directly. One buffer is on screen while they do this, so a changed line can tear for a single frame.
- Change detection:
  - Each text line is padded to 28 characters and drawn with an opaque black background, so a shorter new value fully covers the old one. A line is redrawn only when its text or its highlight changes.
  - The histogram thread copies the counts first, so a bin's label and bar always come from the same reading. A bin is redrawn when its count or its scaled height changes. When the tallest bin grows, every bar rescales, so all bins redraw in that pass.
- Highlighting is now inverted text. The screen is 1-bit, so the old BLUE and RED were just white. The selected encoder setting, the slower core, and a missed frame now show as black text on white.
- The clear skips the UI areas. clear\_ball\_area() clears rows 0–391 with memset, except bytes 0–20 (the text box) on rows 50–203. Nothing below 392 is cleared.
- Balls in the UI areas aren't drawn. Since those areas are never cleared, a ball drawn there would leave a trail. Balls overlapping the text box or the histogram strip are skipped. The visible change: balls disappear just after leaving the bottom peg row, since the histogram strip begins right below it.
- The UI threads yield after every line or bin, so the animation thread can still catch its frame start on time. All of these threads share core 0, so a pass where many lines change still slightly delays the animation thread.
- Timer lines: Clear, Pegs and Balls are per frame. Text and Histogram are now each thread's drawing time for one 20 Hz pass.

Other things to know:

- Each histogram bar is now at most 76 px tall, so it fits between the pegs and the labels.
- Bins 0 and 16 sit outside the walls, so their labels will always read 0.
- The library's clearRect and clearRegion still assume the old 4-bit layout. Nothing calls them now, but don't use them with the 1-bit buffer.
]

#prompt(17)[
the text counter is now up to 3000 us, although i can render more balls. is it possible that the only thing that helped was moving them to slower threads, and the text writing optimization has not helped?
]

#reply[
Yes, mostly. Running at 20 Hz is what's freeing up time. The change detection saves little, because most lines change on every pass. Each redraw also now costs more than the old text drawing did.

- Why skipping unchanged lines doesn't save much. About 10 of the 14 lines change every pass:
- All 8 timing lines. Microsecond readings differ slightly every time, so their text always changes.
- "Total Balls", which goes up whenever a ball reaches the bottom.
- "seconds since boot", once a second.

Only the four settings lines (Balls, Bounciness, Gravity, Ball Radius) actually stay the same between passes.

- Why each redraw costs more than before. I made three changes to support redrawing only what changed, and each one adds work:
- Opaque background: every pixel of each character cell is written, including the black ones. The old setTextColor(c) path only drew the lit pixels.
- Padding to 28 characters: the blank tail of every line is drawn as well.
- Both buffers: every line is drawn twice.

So one changed line costs 28 chars × 48 pixels × 2 buffers = 2,688 calls to pixelBuffer. Each call does a bounds check and a read-modify-write of one byte. At roughly 15–20 cycles per pixel, about 10 changed lines comes to roughly 400–550k cycles, or 2.7–3.6 ms at 150 MHz. That's consistent with the 3000 µs you're seeing.

Overall, time spent on text per second:

```
┌────────┬──────────┬───────────────────┬───────────┐
│        │ Per pass │ Passes per second │   Total   │
├────────┼──────────┼───────────────────┼───────────┤
│ Before │ ~2 ms    │ 60                │ ~120 ms/s │
├────────┼──────────┼───────────────────┼───────────┤
│ Now    │ ~3 ms    │ 20                │ ~60 ms/s  │
└────────┴──────────┴───────────────────┴───────────┘
```

The drop is about 2×, and it comes from the lower rate. Per pass, text drawing got about 50% more expensive.

What would make text drawing itself fast: the text box starts at x = 0, and a full line is exactly 168 px = 21 bytes. So a line can be built one pixel row at a time in a register, then written with whole-byte stores, instead of pixel by pixel:

+ At startup, convert the font from columns to rows: for each character and each of its 8 rows, store a 6-bit pattern. That's a 2 KB table.
+ For each of the 8 pixel rows of a line, shift each character's 6-bit pattern into an accumulator. Each time 8 bits are ready, write out a byte, inverted if the line is highlighted.
+ Copy the resulting 21-byte row into both buffers.

That comes to about 8 × (28 shifts + 21 bytes × 2 buffers) of simple work per line, versus 2,688 masked pixel writes now. I'd estimate 20–30× faster, bringing 10 changed lines down to around 100–150 µs per pass. The histogram labels could use the same approach, but they don't start on a byte boundary, so they'd need an extra shift step.

A cheaper partial fix is to refresh the 8 timing lines less often, say at 4 Hz. That only removes passes, though; each redraw stays just as expensive.

Want me to implement the row-at-a-time text drawing?
]

#prompt(18)[
don't do that. make the text and histogram rendering as they were pre optimization, but keep them in the slow threads rather than the main animation loop. but putting the histogram counts at the bottom is good keep that as well
]

#reply[
Now I'm removing the buffer-targeted drawing helpers I added to the library, since nothing uses them anymore.
]

#reply[
The library files use Windows line endings, so my match failed. The only changes to the .c file were mine, so I'll restore it from git, then put back just the extern declarations in the header.
]

#reply[
The text and histogram now draw exactly as they did before my optimization, but in their own 20 Hz threads. The bin counts stay at the bottom of the screen. It builds; I haven't run it on the board.

- Restored:
- The text and histogram drawing is the original code again (setTextColor / setCursor / writeString and drawRect), now in protothread\_text and protothread\_hist.
- Each thread redraws its whole area on every pass. There's no change detection, no padding, and only lit pixels are drawn, as before.
- I removed drawStringBuffer, fillRectBuffer and drawRectBuffer from the VGA library. The library .c file is back to its committed version.

- Kept:
- Bin counts on the bottom text row (y = 472), with bars ending just above them at y = 470.
- 20 Hz threads, and the animation thread doesn't clear or draw balls in the text box or histogram strip.
- The extern declarations for vga\_buffer\_0, vga\_buffer\_1 and current\_draw\_buffer in the header, which the threads use.

- Two small additions each thread now needs:
- Clear first. The animation thread no longer clears these areas, and the original text is drawn with a transparent background. So each pass first clears its own area with a memset, otherwise new digits would land on top of old ones.
- Copy to the other buffer. The library calls draw only into the hidden buffer. Without a copy, the two buffers would hold text from different passes and changing numbers would flicker. After drawing, each thread copies its rows across with memcpy: about 3 KB for the text box and 7 KB for the histogram strip. If a vsync swaps buffers partway through a pass, that pass can come out partly drawn for up to 50 ms, until the next pass fixes it.

As before, the BLUE and RED highlight colors show as plain white on the 1-bit display, so the selected setting and the slower core aren't visually marked. The Text and Histogram timers now include the clear and the copy.
]

#prompt(19)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

text tearing is fine, you can remove the copy to the other buffer
]

#reply[
I removed the copy to the other buffer, and it builds. Each pass now clears its own area in whichever buffer is current, then draws into it. I haven't run it on the board.

Beyond tearing, expect one more visual effect. Each pass now updates only one of the two buffers, and the display alternates between them every frame. A value that changes between passes, like the timers or Total Balls, will flicker between its old and new value at 60 Hz until the other buffer gets redrawn. A pass runs about every 3 frames, so the two buffers mostly take turns and each one is refreshed about every 100 ms. Lines that don't change look steady.
]

#prompt(20)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

the text below / around Ball Radius tends to flicker -- the histogram text and boxes do not
]

#reply[
Here's what I think is happening. The text pass straddles a buffer swap.

+ The text thread only runs while the animation thread is idle: after it finishes drawing, and while it waits for physics or the next vsync. That idle stretch ends at the vsync.
+ The text pass takes about 2–3 ms, so the vsync usually lands partway through it, at roughly the same point each time.
+ Lines drawn before the swap go into one buffer. The first buffer also got the whole-box clear but never receives the remaining lines, so they show up blank there.
+ Lines after the swap go into the other buffer, which was never cleared, so the new digits land on top of the old ones.

That's why the lines from about Ball Radius down flicker. The histogram pass is short, so it rarely gets caught by a swap.

I'll check the thread code before fixing it.
]

#reply[
I'll make each text line self-contained, clearing its own 8 rows before drawing and only starting if there's enough time before the next buffer swap—ensuring every line renders completely within a single buffer while still using only the animation thread's idle time.
]

#reply[
PowerShell(ninja -C build 2\>&1 | Select-Object -Last 3)
]

#reply[
I think the flicker comes from the text pass getting cut off by a buffer swap, and I've changed the text thread to avoid that. It builds; I haven't run it on the board, so I can't yet confirm it fixes what you're seeing.

- Why the lines around Ball Radius flicker:
+ The text thread only gets to run while the animation thread is idle, which is the stretch after drawing and before the next vsync. A full text pass takes 2–3 ms, so the vsync usually lands partway through it.
+ The pass started by clearing the whole text box in the current buffer. After the swap, the remaining lines went into the other buffer.
+ The first buffer was left with those lower lines cleared but never redrawn. The second buffer got new digits drawn over old text that was never cleared.
+ Because the swap tends to land at about the same point in each pass, the trouble showed up from around Ball Radius down.

The histogram pass is short, so a swap rarely catches it.

- What changed:
- Each line clears and draws itself. It clears only its own 8 rows right before drawing, instead of the whole box being cleared at the start of the pass. A line is complete in whichever buffer it went to. The drawing calls (setTextColor, setCursor, writeString) and the line contents are the same as before; the formatting moved into format\_text\_line().
- A line won't start too close to a swap. It only starts if at least 2 ms remain before the next one. The animation thread now records frame\_start\_us when it begins each frame, and the next swap comes about 16,667 µs after that. The thread also yields between lines, so the animation thread still catches its frame start on time.

- What can still happen:
- Changing values can still shimmer. A line is redrawn into whichever buffer is current, so the two buffers can briefly hold slightly different values for a fast-changing number. That's the effect you said was fine.
- Text can stall if Draw gets near 14.6 ms. If the animation's Draw time reaches about 14.6 ms, the idle stretch before each swap becomes too short to start a line. Text would then update slowly or stop updating, so watch the Draw readout if you add more balls.
]

#prompt(21)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

it looks like when i hit around 13k balls, the text and histogram stop refreshing
]

#reply[
I traced the text stall to the deadline gate never finding a safe window once Draw time exceeds \~14.7ms, while the histogram likely just looks frozen due to a stable distribution or encoder resets rather than actually stopping. I'll fix the text thread to fall back to drawing when no safe window exists—let me know if the histogram count labels truly freeze and I'll dig deeper into that.
]

#reply[
Adding a fallback so a line draws anyway after waiting two frames for a safe window.
]

#reply[
The text no longer freezes: when it hasn't found a safe moment to draw a line within two frames (about 33 ms), it draws that line anyway. The firmware builds, but I haven't run it on the board.

- Normally: a line only starts at least 2 ms before the next buffer swap, so it never gets split across buffers.
- At high ball counts: around 13k balls the animation's Draw time probably leaves no such window, or frames overrun. Each line then waits up to two frames and draws regardless, so it may tear.

With the fallback in play, each of the 14 lines waits about 33 ms. A full pass then takes roughly 0.5 s, so the text refreshes about twice a second instead of 20 times. If you'd rather keep 20 Hz and accept more tearing, I can make one fallback skip the wait for the rest of that pass.

At this point it's also worth watching Draw and Frame on screen. When there's no time left in the frame for the text, the frame budget is already used up, and the missed-frame LED should be on.

For the histogram, check whether the count labels at the bottom are still going up. If they really stop, it's a separate problem.
]

#prompt(22)[
revert this change. make the LED reflect when we are missing timing, i.e. when any of the threads havent made it in time. currently the led is not illuminated even when the text is not being refreshed
]

#reply[
Reverted. Now I'll have each UI thread record when it finishes a pass, and drive the LED from those times plus the frame time.
]

#reply[
Seeding each thread's completion time at its start, so the LED doesn't light during boot before either thread has finished a pass.
]

#reply[
I reverted the text fallback, and the LED now also lights when the text or histogram thread falls behind, not just when a frame overruns. It builds; I haven't run it on the board.

Revert: a text line again only starts when at least 2 ms remain before the next buffer swap, as before. At around 13k balls the text will stop refreshing again, but the LED now shows it.

- LED logic:
- Each UI thread records when it last finished a full pass (text\_done\_us, hist\_done\_us).
- A thread counts as late once 100 ms (UI\_LATE\_US) pass without it finishing a pass. That's its 50 ms sleep plus 50 ms to draw.
- At the end of every frame, the animation thread sets:

```
gpio_put(LED_PIN, missed || ui_late);
```

Here missed is the existing frame-overrun check (Frame \> 16,667 µs), and ui\_late is true if either UI thread is late.

That covers the case you hit. Frames were finishing on time, so missed stayed false, while the text thread had no time window to draw in. With the new check, the LED comes on about 100 ms after the text stops updating.

- Two details:
- Each thread sets its finish time when it starts up, so the LED doesn't light during boot.
- The inverted highlight on the on-screen "Frame" line still only means a frame overran. Only the LED includes the UI threads.
]

#prompt(23)[
#ide-note[IDE context: opened `c:\Users\scorp\OneDrive\Desktop\ECE\5730\digital-galton-board\encoder.c`.]

i just checked out the old commit because these changes haven't gotten me more balls. can you revert the two commits for separate histogram and text threads
]

#reply[
main sits at 4963900, and the detached HEAD has an uncommitted tweak (MAX\_NUM\_BALLS to 20000, num\_balls to 12000). I'll stash that change, revert both commits on main in one new commit, verify the result matches 12c59cb, then reapply the stashed change.
]

#reply[
Both commits are reverted on main, and the code is back to the version before the separate threads. Your ball-count change is still in place uncommitted, and it builds.

- The revert: one new commit, a1c0c99 "Revert separate text and histogram threads", undoes 4963900 ("text threads") and 9c13500 ("text and histogram thread"). The code it leaves is identical to 12c59cb, the commit you had checked out.
- Your uncommitted change: you had MAX\_NUM\_BALLS set to 20000 and num\_balls to 12000 on the old commit. I stashed it, switched to main, made the revert, and re-applied it. It's in the working tree, not committed.

main is now 2 commits ahead of origin/main. 9c13500 was already pushed, so the revert is the safe way to undo it instead of rewriting history. I haven't pushed anything.

The last LED change, which also lights it when the UI threads fall behind, was never committed. It isn't in the working tree, and it isn't in the stash list either. That's fine, since it only applied to the reverted threads. The old stash from "99da825 working" is untouched.
]
