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

#include "pico/stdlib.h"
#include "pico/divider.h"

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
#define TRANSITIONS_PER_CLICK 4

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


volatile int encoder_count = 0;


void gpio_callback(uint gpio, uint32_t event_mask) {
    encoder_count = gpio_get(ENC_B) ? encoder_count + 1 : encoder_count - 1;
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
#define GRAVITY     float2fix15(0.37)
#define BOUNCINESS  float2fix15(0.5)

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

boid_t ball;
peg_t peg;
char color = WHITE;

void spawnBall(boid_t* b) {
    b->x = int2fix15(320);
    b->y = int2fix15(115);
    b->vx = 0;
    b->vy = 0;
}

void updateBall(boid_t* b, peg_t* p) {
    b->x += b->vx;
    b->y += b->vy;

    fix15 dx = b->x - p->x;
    fix15 dy = b->y - p->y;
    fix15 col_dist = int2fix15(BALL_RADIUS + PEG_RADIUS);

    static int last_peg = -1;
    int colliding = 0;

    if (absfix15(dx) < col_dist && absfix15(dy) < col_dist) {
        float fdx = fix2float15(dx);
        float fdy = fix2float15(dy);
        float fdist = sqrtf(fdx * fdx + fdy * fdy);
        fix15 distance = float2fix15(fdist);

        if (distance > 0 && distance < col_dist) {
            colliding = 1;

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

            int current_peg = 0;
            if (current_peg != last_peg) {
                b->vx = multfix15(BOUNCINESS, b->vx);
                b->vy = multfix15(BOUNCINESS, b->vy);

                fix15 impulse = (rand() & 1) ? float2fix15(0.2) : float2fix15(-0.2);
                b->vx += impulse;

                dma_chirp();

                last_peg = current_peg;
            }
        }
    }

    if (!colliding) {
        last_peg = -1;
    }

    if (b->y > int2fix15(480 - BALL_RADIUS)) {
        spawnBall(b);
        last_peg = -1;
        return;
    }

    if (b->x < int2fix15(100 + BALL_RADIUS)) {
        b->vx = -b->vx;
        b->x = int2fix15(100 + BALL_RADIUS);
    } else if (b->x > int2fix15(540 - BALL_RADIUS)) {
        b->vx = -b->vx;
        b->x = int2fix15(540 - BALL_RADIUS);
    }

    if (b->y < int2fix15(100 + BALL_RADIUS)) {
        b->vy = -b->vy;
        b->y = int2fix15(100 + BALL_RADIUS);
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

static PT_THREAD (protothread_anim(struct pt *pt))
{
    PT_BEGIN(pt);

    static char buf[16];

    spawnBall(&ball);

    while (1) {
        PT_YIELD_UNTIL(pt, draw_start_signal());
        clearLowFrame(0, BLACK);

        updateBall(&ball, &peg);

        fillCircle(fix2int15(peg.x), fix2int15(peg.y), PEG_RADIUS, WHITE);
        fillCircle(fix2int15(ball.x), fix2int15(ball.y), BALL_RADIUS, color);

        setTextColor(WHITE);
        setTextSize(3);
        setCursor(80, 40);
        sprintf(buf, "%d", encoder_count / TRANSITIONS_PER_CLICK);
        writeString(buf);
    }

    PT_END(pt);
}

int main() {
    set_sys_clock_khz(150000, true);
    stdio_init_all();
    initVGA();
    init_dma_chirp();

    peg.x = int2fix15(320);
    peg.y = int2fix15(240);

    gpio_init(ENC_A);
    gpio_init(ENC_B);
    gpio_set_dir(ENC_A, GPIO_IN);
    gpio_set_dir(ENC_B, GPIO_IN);
    gpio_pull_up(ENC_A);
    gpio_pull_up(ENC_B);


    gpio_set_irq_enabled_with_callback(ENC_A,
        GPIO_IRQ_EDGE_RISE, true, &gpio_callback);

    pt_add_thread(protothread_serial);
    pt_add_thread(protothread_anim);

    pt_schedule_start;

    return 0;
}