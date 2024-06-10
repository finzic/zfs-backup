#!/bin/bash
function parse_size() {
    size=$1
    suffix="${size: -1}"
    num="${size%$suffix}"
    integer_part="${num%%.*}"

    if [ x${integer_part} = x${num} ];
    then
        echo "${size}"
    else
        value="$(echo "${num}*1024" | bc)"
        case "$suffix" in
                "K")
                    echo "${value%%.*}"
                    ;;
                "M")
                    echo "${value%%.*}K"
                    ;;
                "G")
                    echo "${value%%.*}M"
                    ;;
                "T")
                    echo "${value%%.*}G"
                    ;;
                *)
                    echo "Invalid size. Please enter a size in K, M, or G."
                    ;;
        esac
    fi
}

parse_size $1

