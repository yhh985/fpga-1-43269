"""Seal clock-order recovery with regression evidence and unchanged old releases."""
from package_audio_clock_probe import main

if __name__=='__main__':
    main(release='audio_autoclock_20261021',bit_suffix='autoclock',
         document='docs/音效自动时钟修正版20261021.md',
         extra_files=['tools/package_audio_autoclock.py',
                      'verification/audio_autoclock_review.json',
                      'verification/pin_audit_20261021/hx_gpio.png',
                      'verification/pin_audit_20261021/hx_fpga.png',
                      'verification/pin_audit_20261021/aca_gpio.png'])
