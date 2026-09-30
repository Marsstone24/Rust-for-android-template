use std::process::exit;

use macroquad::prelude::*;

fn window_conf() -> Conf {
    Conf {
        window_title: "Rust x Macroquad on android!".to_string(),
        high_dpi: true,
        ..Default::default()
    }
}

pub fn main() {
    exit(0);
}

pub async fn entry() {
    let mut pos = vec2(screen_width() / 2.0, screen_height() / 2.0);

    loop {
        clear_background(WHITE);

        for touch in touches() {
            if touch.phase == TouchPhase::Started {
                pos = touch.position;
            }
        }
        draw_circle(pos.x, pos.y, 40.0, VIOLET);
        next_frame().await;
    }
}

// 2. C-Export für Miniquad
#[unsafe(no_mangle)]
pub extern "C" fn quad_main() {
    macroquad::Window::from_config(window_conf(), entry());
}