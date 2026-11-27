;; The Mandelbrot set, drawn by WebAssembly for the README's Tuxcat
;; screenshot (docs/screenshots/pages/webassembly.html): render(width,
;; height, iterations) writes RGBA pixels into the exported memory.
(module
  (memory (export "memory") 32)
  ;; A colour channel rising with the escape count: base + count * step,
  ;; held at 255.
  (func $channel (param $count i32) (param $step i32) (param $base i32) (result i32)
    (local $value i32)
    (local.set $value (i32.add (local.get $base) (i32.mul (local.get $count) (local.get $step))))
    (select (i32.const 255) (local.get $value) (i32.gt_s (local.get $value) (i32.const 255))))
  (func (export "render") (param $width i32) (param $height i32) (param $limit i32)
    (local $x i32) (local $y i32) (local $count i32) (local $pixel i32)
    (local $cr f64) (local $ci f64) (local $zr f64) (local $zi f64) (local $next f64)
    (local.set $y (i32.const 0))
    (block $rows_done
      (loop $rows
        (br_if $rows_done (i32.ge_s (local.get $y) (local.get $height)))
        (local.set $x (i32.const 0))
        (block $columns_done
          (loop $columns
            (br_if $columns_done (i32.ge_s (local.get $x) (local.get $width)))
            (local.set $cr (f64.sub (f64.mul (f64.div (f64.convert_i32_s (local.get $x))
                                                      (f64.convert_i32_s (local.get $width)))
                                             (f64.const 3.2))
                                    (f64.const 2.3)))
            (local.set $ci (f64.sub (f64.mul (f64.div (f64.convert_i32_s (local.get $y))
                                                      (f64.convert_i32_s (local.get $height)))
                                             (f64.const 2.4))
                                    (f64.const 1.2)))
            (local.set $zr (f64.const 0))
            (local.set $zi (f64.const 0))
            (local.set $count (i32.const 0))
            (block $escaped
              (loop $iterate
                (br_if $escaped (i32.ge_s (local.get $count) (local.get $limit)))
                (br_if $escaped (f64.gt (f64.add (f64.mul (local.get $zr) (local.get $zr))
                                                 (f64.mul (local.get $zi) (local.get $zi)))
                                        (f64.const 4)))
                (local.set $next (f64.add (f64.sub (f64.mul (local.get $zr) (local.get $zr))
                                                   (f64.mul (local.get $zi) (local.get $zi)))
                                          (local.get $cr)))
                (local.set $zi (f64.add (f64.mul (f64.mul (f64.const 2) (local.get $zr)) (local.get $zi))
                                        (local.get $ci)))
                (local.set $zr (local.get $next))
                (local.set $count (i32.add (local.get $count) (i32.const 1)))
                (br $iterate)))
            (local.set $pixel (i32.shl (i32.add (i32.mul (local.get $y) (local.get $width)) (local.get $x))
                                       (i32.const 2)))
            (if (i32.ge_s (local.get $count) (local.get $limit))
              (then (i32.store (local.get $pixel) (i32.const 0xff1e0c10)))
              (else
                (i32.store8 (local.get $pixel) (call $channel (local.get $count) (i32.const 10) (i32.const 8)))
                (i32.store8 offset=1 (local.get $pixel) (call $channel (local.get $count) (i32.const 4) (i32.const 6)))
                (i32.store8 offset=2 (local.get $pixel) (call $channel (local.get $count) (i32.const 7) (i32.const 40)))
                (i32.store8 offset=3 (local.get $pixel) (i32.const 255))))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $columns)))
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $rows)))))
