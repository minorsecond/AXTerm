import Foundation; var t = termios(); t.c_cc.16 = 1; print(t.c_cc.16)
