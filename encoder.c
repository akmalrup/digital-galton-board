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
#define IRQ_SIG 13

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
#define NUM_BINS    10
#define BIN_WIDTH   (640 / NUM_BINS)

int data_chan;

void dma_chirp(void) {
    dma_channel_abort(data_chan);
    dma_channel_set_read_addr(data_chan, DAC_data, false);
    dma_channel_set_trans_count(data_chan, CHIRP_SAMPLES, true);
}

void init_dma_chirp(void) {
    for (int i = 0; i < sine_table_size; i++) {
        int raw_sin = (int)(2047.0 * sin((float)i * 6.28318530718 / (float)sine_table_size) + 2047.0);
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


#define MAX_NUM_BALLS 256
volatile int num_balls = 10;
volatile int fallen_balls = 0;
volatile int encoder_count = 0;

void gpio_callback(uint gpio, uint32_t event_mask) {
    int enc_b_read = gpio_get(ENC_B);
    int enc_incr = (enc_b_read) ? 1 : -1;
    encoder_count += enc_incr;
    num_balls += enc_incr;
    if (num_balls < 0) {
        num_balls = 0;
    } else if (num_balls > MAX_NUM_BALLS) {
        num_balls = MAX_NUM_BALLS;
    }
}

typedef signed int fix15;
#define multfix15(a,b) ((fix15)((((signed long long)(a))*((signed long long)(b)))>>15))
#define float2fix15(a) ((fix15)((a)*32768.0))
#define fix2float15(a) ((float)(a)/32768.0)
#define absfix15(a) abs(a)
#define int2fix15(a) ((fix15)(a << 15))
#define fix2int15(a) ((int)(a >> 15))
#define divfix(a,b) (fix15)(div_s64s64((((signed long long)(a)) << 15), ((signed long long)(b))))

#define BALL_RADIUS 4
#define PEG_RADIUS  6
#define GRAVITY     float2fix15(0.6)
#define BOUNCINESS  float2fix15(0.3)

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


int histogram[NUM_BINS] = {0};

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

void checkBallCollision(boid_t* b, peg_t* p) {
    fix15 col_dist = int2fix15(BALL_RADIUS + PEG_RADIUS);

    fix15 dx = b->x - p->x;
    fix15 dy = b->y - p->y;

    if (absfix15(dx) < col_dist && absfix15(dy) < col_dist) {
        float fdx = fix2float15(dx);
        float fdy = fix2float15(dy);
        float fdist = sqrtf(fdx * fdx + fdy * fdy);
        fix15 distance = float2fix15(fdist);

        if (distance > 0 && distance < col_dist) {

            if (fabsf(fdx) < 0.5f) {
                fdx = (rand() & 1) ? 2.0f : -2.0f;
                fdist = sqrtf(fdx * fdx + fdy * fdy);
            }

            fix15 normal_x = float2fix15(fdx / fdist);
            fix15 normal_y = float2fix15(fdy / fdist);

            fix15 intermediate_term = -2 * (multfix15(normal_x, b->vx) + multfix15(normal_y, b->vy));

            fix15 teleport_dist = int2fix15(PEG_RADIUS + BALL_RADIUS + 1);
            b->x = p->x + multfix15(normal_x, teleport_dist);
            b->y = p->y + multfix15(normal_y, teleport_dist);

            if (intermediate_term > 0) {
                b->vx += multfix15(normal_x, intermediate_term);
                b->vy += multfix15(normal_y, intermediate_term);
            }

            b->vx = multfix15(BOUNCINESS, b->vx);
            b->vy = multfix15(BOUNCINESS, b->vy);

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

    if (b->y > int2fix15(480 - BALL_RADIUS)) {
        int x_pixel = fix2int15(b->x);
        int bin = x_pixel / BIN_WIDTH;
        if (x_pixel >= 0 && bin >= 0 && bin < NUM_BINS) {
            histogram[bin]++;
        }
        spawnBall(b);
        fallen_balls++;
        return;
    }

    if (b->x < int2fix15(35 + BALL_RADIUS)) {
        b->vx = -b->vx;
        b->x = int2fix15(35 + BALL_RADIUS);
    } else if (b->x > int2fix15(605 - BALL_RADIUS)) {
        b->vx = -b->vx;
        b->x = int2fix15(605 - BALL_RADIUS);
    }

    if (b->y < int2fix15(BALL_RADIUS)) {
        b->vy = -b->vy;
        b->y = int2fix15(BALL_RADIUS);
    }

    b->vy += GRAVITY;
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

void normalize_histogram(int* hist) {
    int max = 0;
    for (int i = 0; i < NUM_BINS; i++) {
        if (hist[i] > max) {
            max = hist[i];
        }
    }
    if (max > HIST_HEIGHT) {
        for (int i = 0; i < NUM_BINS; i++) {
            hist[i] = (hist[i] * HIST_HEIGHT) / max;
        }
    }
}


void draw_histogram(int* hist) {
    for (int i = 0; i < NUM_BINS; i++) {
        int height = hist[i];
        if (height > 0) {
            if (height > HIST_HEIGHT) { 
                height = HIST_HEIGHT; 
            }
            normalize_histogram(hist);
            fillRect(i * BIN_WIDTH, 480 - height, BIN_WIDTH, height, BLUE);
        }
    }
}


static PT_THREAD (protothread_anim(struct pt *pt))
{
    PT_BEGIN(pt);

    static char buf[16];

    for (int i = 0; i < MAX_NUM_BALLS; i++) {
        spawnBall(&ball[i]);
    }

    while (1) {
        PT_YIELD_UNTIL(pt, draw_start_signal());
        clearLowFrame(0, BLACK);

        for (int i = 0; i < num_balls; i++) {
            updateBallPhysics(&ball[i]);
        }

        for (int i = 0; i < 136; i++) {
            fillCircle(fix2int15(peg[i].x), fix2int15(peg[i].y), PEG_RADIUS, WHITE);
            for (int j = 0; j < num_balls; j++) {
                checkBallCollision(&ball[j], &peg[i]);
            }
        }
        for (int i = 0; i < num_balls; i++) {
            fillCircle(fix2int15(ball[i].x), fix2int15(ball[i].y), BALL_RADIUS, color);
        }

        draw_histogram(histogram);

        setTextColor(WHITE);
        setTextSize(1);
//
//        setCursor(1, 50);
//        sprintf(buf, "Balls: %d", num_balls);
//        writeString(buf);
//

       setCursor(1, 60);
       sprintf(buf, "Total Balls: %d", fallen_balls);
       writeString(buf);
//
//        struct timespec current_time;
//        aon_timer_get_time(&current_time);
//
//        setCursor(1, 70);
//        sprintf(buf, "seconds since boot: %d", (int)current_time.tv_sec);
//        writeString(buf);
        
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
    gpio_init(IRQ_SIG);
    gpio_set_dir(ENC_A, GPIO_IN);
    gpio_set_dir(ENC_B, GPIO_IN);
    gpio_set_dir(IRQ_SIG, GPIO_OUT);
    gpio_pull_up(ENC_A);
    gpio_pull_up(ENC_B);


    gpio_set_irq_enabled_with_callback(ENC_A,
        GPIO_IRQ_EDGE_FALL, true, &gpio_callback);

    pt_add_thread(protothread_serial);
    pt_add_thread(protothread_anim);

    pt_schedule_start;

    return 0;
}