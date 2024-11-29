#![no_std]
#![no_main]

use core::ffi::c_char;
use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

#[no_mangle]
extern "C" fn _start() {
    const HELLO_PTR: *const c_char = {
	const BYTES: &[u8] = b"Hellorld from an ELF file\0";
	BYTES.as_ptr().cast()
    };

    unsafe {
	core::arch::asm!(
	    "syscall",

	    in("rax") 1 as usize,
	    in("rdx") HELLO_PTR,
	);
    }

    loop {}
}
