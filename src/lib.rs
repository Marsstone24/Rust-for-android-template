use macroquad::prelude::*;

async fn entry() {
    loop {
        clear_background(DARKBLUE);
        draw_text("Hello from Rust on Android!", 40.0, 80.0, 40.0, WHITE);
        next_frame().await
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn quad_main() {
    macroquad::Window::new("Hello", entry());
}
