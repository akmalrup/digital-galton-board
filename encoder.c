/**
 * ECE 4760 / 5730 - Lab 2 (Digital Galton Board)
 *
 * Rotary encoder interface + VGA ball & peg simulation:
 *  - Displays rotary encoder position on VGA display
 *  - Simulates one ball bouncing off a central peg under gravity
 *  - Serial console interface allows changing ball color (1-15)
 *
 * HARDWARE CONNECTIONS
 *  - GPIO 14 ---> Encoder channel A
 *  - GPIO 15 ---> Encoder channel B
 *  - GND     ---> Encoder COM
 *
 *  - GPIO 16 ---> VGA Hsync
 *  - GPIO 17 ---> VGA Vsync
 *  - GPIO 18 ---> VGA Green lo-bit --> 470 ohm resistor --> VGA_Green
 *  - GPIO 19 ---> VGA Green hi-bit --> 330 ohm resistor --> VGA_Green
 *  - GPIO 20 ---> 330 ohm resistor ---> VGA-Blue
 *  - GPIO 21 ---> 330 ohm resistor ---> VGA-Red
 *  - RP2040 GND ---> VGA-GND
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


// Screen layout. The UI text box (top left) and the histogram strip (bottom)
// are drawn into both framebuffers only when they change, by their own
// threads. The animation thread never clears or draws inside them.

#define VGA_ROW_BYTES 80            // 640 px per row at 1 bit per pixel

// UI text box: 28 chars of the 6 px wide font, from x = 0
#define TEXT_LINE_CHARS 28
#define TEXT_RIGHT      (TEXT_LINE_CHARS * 6)   // 168 px, a whole number of bytes
#define TEXT_TOP        50
#define TEXT_BOTTOM     204

// histogram strip: from just below the bottom peg row (y = 385 + PEG_RADIUS)
// to the bottom of the screen, with bin count labels on the last text row
#define HIST_TOP        392
#define HIST_BAR_BOTTOM 470
#define HIST_LABEL_Y    472
#define HIST_HEIGHT     (HIST_BAR_BOTTOM - HIST_TOP - 2)   // 76 px tallest bar
#define NUM_BINS    17
#define BIN_WIDTH   38
// x of bin 0's left edge. Chosen so the middle bin (8) spans [301, 339),
// centered on the board's center x = 320, with bin edges on the bottom-row pegs
#define HIST_LEFT   (320 - BIN_WIDTH / 2 - (NUM_BINS / 2) * BIN_WIDTH)

// UI and histogram refresh period: 20 Hz
#define UI_PERIOD_US 50000
// A UI thread counts as late (LED on) if it hasn't finished a pass this long
// after its previous one: one period of sleep plus one period to draw
#define UI_LATE_US   (2 * UI_PERIOD_US)

int data_chan;

void dma_chirp(void) {
    dma_channel_set_trans_count(data_chan, CHIRP_SAMPLES, true);
}

void init_dma_chirp(void) {
    for (int i = 0; i < sine_table_size; i++) {
        float progress = (float)i / (float)sine_table_size;
        float envelope = (1.0f - progress) * expf(-2.5f * progress);
        int raw_sin = 2048 + (int)(2047.0f * envelope * sinf((float)i * 6.28318530718f / (float)sine_table_size));
        DAC_data[i] = (unsigned short)(DAC_config_chan_A | (raw_sin & 0x0FFF));
    }

    spi_init(SPI_PORT, 20000000);
    spi_set_format(SPI_PORT, 16, 0, 0, 0);
    gpio_set_function(PIN_MISO, GPIO_FUNC_SPI);
    gpio_set_function(PIN_CS,   GPIO_FUNC_SPI);
    gpio_set_function(PIN_SCK,  GPIO_FUNC_SPI);
    gpio_set_function(PIN_MOSI, GPIO_FUNC_SPI);

    // Initial neutral mid-scale output
    uint16_t neutral = DAC_config_chan_A | 2048;
    spi_write16_blocking(SPI_PORT, &neutral, 1);

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
volatile int num_balls = 13000;
volatile int fallen_balls = 0;
volatile int encoder_count = 0;

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

    reset_histogram();
    fallen_balls = 0;
}

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
    fix15 col_dist = int2fix15(ball_radius + PEG_RADIUS+1);

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


// Timing shown in the UI (all written on core 0 except physics_us)
volatile uint32_t physics_us = 0;
static uint32_t draw_us, frame_us, clear_us, pegs_us, balls_us, text_us, hist_us;
static bool missed = false;                 // last animation frame overran 60 fps
// when each UI thread last finished a full pass (for the late-thread LED)
static uint32_t text_done_us, hist_done_us;

// The UI threads draw with the normal library calls, into whichever buffer
// is current_draw_buffer at the time. The animation thread never clears the
// UI areas, so the UI threads clear what they redraw. The two buffers get
// updated on different passes, so changing values can flicker between them.
static void clear_rows(char* buf, int y0, int y1, int byte0, int byte1) {
    for (int y = y0; y < y1; y++) {
        memset(buf + y * VGA_ROW_BYTES + byte0, 0, byte1 - byte0);
    }
}

int bar_heights[NUM_BINS];

void draw_histogram(int* hist) {
    normalize_histogram(hist, bar_heights);

    for (int i = 0; i < NUM_BINS; i++) {
        if (bar_heights[i] > 0) {
            drawRect(HIST_LEFT + i * BIN_WIDTH, HIST_BAR_BOTTOM - bar_heights[i],
                     BIN_WIDTH - 2, bar_heights[i], BLUE);
        }
        // print count at the bottom of the screen, under its bin

        char buf[32];
        setTextColor(WHITE);
        setCursor(HIST_LEFT + i * BIN_WIDTH, HIST_LABEL_Y);
        sprintf(buf, "%d", histogram[i]);
        writeString(buf);
    }
}

// Histogram thread, 20 Hz
static PT_THREAD (protothread_hist(struct pt *pt))
{
    PT_BEGIN(pt);

    hist_done_us = time_us_32();   // not late before the first pass

    while (1) {
        uint32_t t0 = time_us_32();
        clear_rows(current_draw_buffer, HIST_TOP, 480, 0, VGA_ROW_BYTES);
        draw_histogram(histogram);
        hist_us = time_us_32() - t0;
        hist_done_us = time_us_32();

        PT_YIELD_usec(UI_PERIOD_US);
    }

    PT_END(pt);
}

// Text for UI text line `line` (written into out), and the color to draw it
#define TEXT_LINES 14
static const short text_line_y[TEXT_LINES] = {
    50, 60, 70, 80, 90, 100,        // stats and encoder-adjustable settings
    120, 130, 140,                  // per-core timing
    155, 165, 175, 185, 195,        // time per stage
};

static char format_text_line(int line, char* out) {
    uint32_t phys = physics_us;
    switch (line) {
    // 1. Total Balls
    case 0: sprintf(out, "Total Balls: %d", fallen_balls); return WHITE;
    // 2. Seconds since boot
    case 1: {
        struct timespec current_time;
        aon_timer_get_time(&current_time);
        sprintf(out, "seconds since boot: %d", (int)current_time.tv_sec);
        return WHITE;
    }
    // 3. Balls (active selection highlight)
    case 2: sprintf(out, "Balls: %d", num_balls);
            return pusher_state == BALLS ? BLUE : WHITE;
    // 4. Bounciness (active selection highlight)
    case 3: {
        float f_bounce = fix2float15(bounciness);
        int bounce_whole = (int)f_bounce;
        int bounce_hundredths = (int)((f_bounce - bounce_whole) * 100.0f + 0.5f);
        if (bounce_hundredths < 0) bounce_hundredths = -bounce_hundredths;
        sprintf(out, "Bounciness: %d.%02d", bounce_whole, bounce_hundredths);
        return pusher_state == _BOUNCINESS ? BLUE : WHITE;
    }
    // 5. Gravity (active selection highlight)
    case 4: {
        float f_grav = fix2float15(gravity);
        int grav_whole = (int)f_grav;
        int grav_hundredths = (int)((f_grav - grav_whole) * 100.0f + 0.5f);
        if (grav_hundredths < 0) grav_hundredths = -grav_hundredths;
        sprintf(out, "Gravity: %d.%02d", grav_whole, grav_hundredths);
        return pusher_state == _GRAVITY ? BLUE : WHITE;
    }
    // 6. Ball Radius (active selection highlight)
    case 5: sprintf(out, "Ball Radius: %d", ball_radius);
            return pusher_state == _ball_radius ? BLUE : WHITE;
    // 7. Per-core timing (slower core in red)
    case 6: sprintf(out, "Physics (core 1): %lu us", (unsigned long)phys);
            return phys > draw_us ? RED : WHITE;
    case 7: sprintf(out, "Draw (core 0): %lu us", (unsigned long)draw_us);
            return draw_us >= phys ? RED : WHITE;
    case 8: sprintf(out, "Frame: %lu / 16667 us", (unsigned long)frame_us);
            return missed ? RED : WHITE;
    // 8. Time per stage. Clear, pegs and balls are per animation frame;
    // text and histogram are per 20 Hz pass of their own threads
    case 9:  sprintf(out, "  Clear:     %lu us", (unsigned long)clear_us);  return WHITE;
    case 10: sprintf(out, "  Pegs:      %lu us", (unsigned long)pegs_us);   return WHITE;
    case 11: sprintf(out, "  Balls:     %lu us", (unsigned long)balls_us);  return WHITE;
    case 12: sprintf(out, "  Text:      %lu us", (unsigned long)text_us);   return WHITE;
    case 13: sprintf(out, "  Histogram: %lu us", (unsigned long)hist_us);   return WHITE;
    }
    out[0] = '\0';
    return WHITE;
}

// When the animation thread started the current frame. The next buffer swap
// comes about 16667 us later.
static uint32_t frame_start_us;

// A text line must start at least this long before the next buffer swap, so
// it lands entirely in one buffer. Allows for one line (~0.2 ms) plus the
// delay between the vsync and the animation thread noticing it.
#define TEXT_LINE_DEADLINE_US (16667 - 2000)

// UI text thread, 20 Hz. Each line clears only its own rows and is drawn
// whole into the current buffer, so a buffer swap between lines can't leave
// a half-drawn or overdrawn line behind.
static PT_THREAD (protothread_text(struct pt *pt))
{
    PT_BEGIN(pt);

    text_done_us = time_us_32();   // not late before the first pass

    static char buf[48];
    static int line;
    static uint32_t busy_us;

    while (1) {
        busy_us = 0;
        for (line = 0; line < TEXT_LINES; line++) {
            // also yields, so the animation thread can catch its frame start
            PT_YIELD_UNTIL(pt, time_us_32() - frame_start_us < TEXT_LINE_DEADLINE_US);

            uint32_t t0 = time_us_32();
            short y = text_line_y[line];
            char line_color = format_text_line(line, buf);
            clear_rows(current_draw_buffer, y, y + 8, 0, TEXT_RIGHT / 8);
            setTextSize(1);
            setTextColor(line_color);
            setCursor(1, y);
            writeString(buf);
            busy_us += time_us_32() - t0;
        }
        text_us = busy_us;
        text_done_us = time_us_32();

        PT_YIELD_usec(UI_PERIOD_US);
    }

    PT_END(pt);
}



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

static void clear_ball_area(void) {
    char* buf = current_draw_buffer;
    // rows above the text box
    memset(buf, 0, TEXT_TOP * VGA_ROW_BYTES);
    // rows beside the text box: only the part right of it
    for (int y = TEXT_TOP; y < TEXT_BOTTOM; y++) {
        memset(buf + y * VGA_ROW_BYTES + TEXT_RIGHT / 8, 0,
               VGA_ROW_BYTES - TEXT_RIGHT / 8);
    }
    // rows below the text box, down to the histogram strip
    memset(buf + TEXT_BOTTOM * VGA_ROW_BYTES, 0,
           (HIST_TOP - TEXT_BOTTOM) * VGA_ROW_BYTES);
}

static PT_THREAD (protothread_anim(struct pt *pt))
{
    PT_BEGIN(pt);

    // static: protothread locals don't survive PT_SEM_SDK_WAIT's yield
    static uint32_t start, mark;

    for (int i = 0; i < MAX_NUM_BALLS; i++) {
        spawnBall(&ball[i]);
    }

    while (1) {
        PT_YIELD_UNTIL(pt, draw_start_signal());
        //check if we are meeting the 60 fps deadline 
        start = time_us_32();
        frame_start_us = start;

        // Signal Core 1 to compute physics in parallel
        sem_release(&sem_physics_start);

        mark = time_us_32();
        clear_ball_area();
        clear_us = time_us_32() - mark;

        // Core 0 draws pegs while Core 1 calculates physics
        mark = time_us_32();
        for (int i = 0; i < 136; i++) {
            drawCircle(fix2int15(peg[i].x), fix2int15(peg[i].y), PEG_RADIUS, WHITE);
        }
        pegs_us = time_us_32() - mark;

        // Balls inside the UI text box or the histogram strip are skipped:
        // those areas are never cleared here, so they would leave trails
        mark = time_us_32();
        int r = ball_radius;
        int n = num_balls;
        for (int i = 0; i < n; i++) {
            int bx = fix2int15(ball[i].x);
            int by = fix2int15(ball[i].y);
            if (by + r >= HIST_TOP) continue;
            if (bx - r < TEXT_RIGHT && by + r >= TEXT_TOP && by - r < TEXT_BOTTOM) continue;
            drawCircle(bx, by, r, color);
        }
        balls_us = time_us_32() - mark;

        draw_us = time_us_32() - start;

        PT_SEM_SDK_WAIT(pt, &sem_physics_done);

        frame_us = time_us_32() - start;
        missed = frame_us > 16667;

        // LED on if this frame overran, or a UI thread is behind schedule
        uint32_t now = time_us_32();
        bool ui_late = now - text_done_us > UI_LATE_US
                    || now - hist_done_us > UI_LATE_US;
        gpio_put(LED_PIN, missed || ui_late);
    }

    PT_END(pt);
}



struct timespec initial_time = {
    .tv_sec = 0,
    .tv_nsec = 0,
};



int main() {
    set_sys_clock_khz(150000, true);
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

    pt_add_thread(protothread_text);
    pt_add_thread(protothread_anim);
    pt_add_thread(protothread_hist);

    pt_schedule_start;

    return 0;
}