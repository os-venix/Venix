#![no_std]
#![no_main]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

#[no_mangle]
extern "C" fn _start() {
    const HELLO_PTR: &[u8] = b"Hellorld from an ELF file";

    unsafe {
	core::arch::asm!(
	    "syscall",

	    in("rax") 0 as usize,
	    in("rsi") HELLO_PTR.as_ptr(),
	    in("rdi") 1,
	    in("rdx") HELLO_PTR.len(),
	);
    }

    loop {}
}
