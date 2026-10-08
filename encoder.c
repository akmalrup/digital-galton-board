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


// histogram 

#define HIST_HEIGHT 80
#define NUM_BINS    17
#define BIN_WIDTH   38
#define HIST_LEFT -2

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

#define MAX_NUM_BALLS 1024
volatile int num_balls = 470;
volatile int fallen_balls = 0;
volatile int encoder_count = 0;

volatile int ball_radius = 4;

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
    b->x = int2fix15(320);
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

            fix15 teleport_dist = int2fix15(PEG_RADIUS + ball_radius);
            b->x = p->x + multfix15(normal_x, teleport_dist);
            b->y = p->y + multfix15(normal_y, teleport_dist);

            if (intermediate_term > 0) {
                b->vx += multfix15(normal_x, intermediate_term);
                b->vy += multfix15(normal_y, intermediate_term);
            }

            b->vx = multfix15(bounciness, b->vx);
            b->vy = multfix15(bounciness, b->vy);

            fix15 impulse = (rand() & 1) ? float2fix15(0.2) : float2fix15(-0.2);
            b->vx += impulse;

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
        int bin = x_pixel / BIN_WIDTH;
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
//   row r (0..15) is at          y = PEG_TOP_Y + r * PEG_SPACING
//   peg c (0..r) in row r is at  x = PEG_CENTER_X + (2c - r) * PEG_SPACING
//   index of peg (r, c) in peg[] = r*(r+1)/2 + c   (rows stored back to back)
#define PEG_ROWS      16
#define PEG_TOP_Y     100
#define PEG_CENTER_X  320
#define PEG_SPACING   19

// Check a ball only against the pegs it could be touching,
// instead of looping over all 136 pegs.
//
// A ball can only hit a peg if its center is within
// reach = ball_radius + PEG_RADIUS (at most 16 px) of the peg center.
//  - Rows are 19 px apart, so at most 2 rows are close enough vertically.
//  - Pegs in a row are 38 px apart, so only the nearest peg in each row
//    can be close enough horizontally.
// So each ball needs at most 2 calls to checkBallCollision, which still
// does the exact distance test.
static inline void checkNearbyPegs(boid_t* b) {
    // Ball position in whole pixels
    int bx = fix2int15(b->x);
    int by = fix2int15(b->y);
    int reach = ball_radius + PEG_RADIUS;

    // Ball is completely above the first row or below the last row
    if (by + reach < PEG_TOP_Y) return;
    if (by - reach > PEG_TOP_Y + (PEG_ROWS - 1) * PEG_SPACING) return;

    // Find the rows whose y falls within [by - reach, by + reach].
    // row_lo rounds up and row_hi rounds down, so only rows inside that
    // band are included. (C integer division truncates toward zero, which
    // rounds up for the negative values row_lo can get here.)
    int row_lo = (by - reach - PEG_TOP_Y + PEG_SPACING - 1) / PEG_SPACING;
    int row_hi = (by + reach - PEG_TOP_Y) / PEG_SPACING;
    if (row_lo < 0)            row_lo = 0;
    if (row_hi > PEG_ROWS - 1) row_hi = PEG_ROWS - 1;

    for (int r = row_lo; r <= row_hi; r++) {
        // Leftmost peg in row r is at x = PEG_CENTER_X - r * PEG_SPACING,
        // and each next peg is 2 * PEG_SPACING to the right. Adding half
        // that gap (PEG_SPACING) before dividing rounds to the nearest column.
        int row_left_x = PEG_CENTER_X - r * PEG_SPACING;
        int c = (bx - row_left_x + PEG_SPACING) / (2 * PEG_SPACING);

        // Keep c on a peg that exists (row r has r + 1 pegs)
        if (c < 0) c = 0;
        if (c > r) c = r;

        // Exact collision test against that one peg
        checkBallCollision(b, &peg[r * (r + 1) / 2 + c]);
    }
}

static PT_THREAD (protothread_serial(struct pt *pt))
{
    PT_BEGIN(pt);
    static int user_input;
    PT_YIELD_usec(1000000);
    sprintf(pt_serial_out_buffer, "Protothreads RP2040 v1.4\n\r");
    serial_write;
    while (1) {
        sprintf(pt_serial_out_buffer, "input a number in the range 1-15: ");
        serial_write;
        serial_read;
        sscanf(pt_serial_in_buffer, "%d", &user_input);
        if (user_input > 0 && user_input < 16) {
            color = (char)user_input;
        }
    }
    PT_END(pt);
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

    for (int i = 0; i < MAX_NUM_BALLS; i++) {
        spawnBall(&ball[i]);
    }

    while (1) {
        PT_YIELD_UNTIL(pt, draw_start_signal());
        //check if we are meeting the 60 fps deadline 
        start = time_us_32();

        sem_release(&sem_physics_start);

        clearLowFrame(0, BLACK);


        // Signal Core 1 to compute physics in parallel

        // Core 0 draws pegs while Core 1 calculates physics
        for (int i = 0; i < 136; i++) {
            drawCircle(fix2int15(peg[i].x), fix2int15(peg[i].y), PEG_RADIUS, WHITE);
        }



        // Core 0 draws histogram and UI while Core 1 calculates physics
        draw_histogram(histogram);

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

        for (int i = 0; i < num_balls; i++) {
            drawCircle(fix2int15(ball[i].x), fix2int15(ball[i].y), ball_radius, color);
        }

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

    pt_add_thread(protothread_serial);
    pt_add_thread(protothread_anim);

    pt_schedule_start;

    return 0;
}