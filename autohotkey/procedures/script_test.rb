require_utility 'clear_util'

display("INST ADCS")
wait 2
clear("INST ADCS")
set_line_delay(1.5)
delay = get_line_delay
set_line_delay(0)
check_expression("#{delay} == 1.5")
get_scriptrunner_message_log_filename
start_new_scriptrunner_message_log
play_wav_file(File.join(Cosmos::USERPATH,'config','data','tada.wav'))
step_mode
wait 0.5
run_mode
show_backtrace
start("clear_util.rb")
