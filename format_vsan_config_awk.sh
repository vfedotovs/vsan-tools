#!/bin/bash


# whats needed format only vsan used and not pdl
# second iteration PDL only and not VSAN used only

#However, gawk ignores newlines after any of the following symbols and keywords:
#,    {    ?    :    ||    &&    do    else

grep -E "Name|VSANUUID|State|PDL"  vdq.txt \
    | awk -F ": " \
    'BEGIN {
        printf "%-30s | %s | %-38s | %s \n ",
            "Disk_state", "IsPDL", "VSANUUID", "Disk_Name"
        print "------------------------------------------------------------------------------------------"
    } 
    /Name/ {disk_names[naa++]=$2}
    /State/ {disk_states[state++]=$2}
    /VSANUUID/ {disk_uuids[vsanuuid++]=$2}
    /PDL/ {pdl_states[pdl++]=$2}

    END {
        for (idx in disk_names) 
             printf "%-30s | %-6s| %-38s | %s\n", 
                disk_states[idx], 
                pdl_states[idx], 
                disk_uuids[idx], 
                disk_names[idx]
    }'


printf "\n\n"
VSAN_HBA_FILE=localcli_vsan-debug-controller-list.txt
grep -B2 -A4 "Used By VSAN: true" $VSAN_HBA_FILE \
    | grep -E "Device Name|Used|Display|PCI ID|Driver|Queue" \
    | awk -F ": " 'BEGIN {
        print "Used by VSAN| HBA ID   | HBA Name"
        print "------------+----------+-------------------"
    }
    /Device Name/ {hba_ids[hba++]=$2}
    /Display Name/ {hba_names[names++]=$2}
    /Used By VSAN/ {hba_states[state++]=$2}

    /PCI ID/ {pcis[pci++]=$2}
    /Driver Name/ {dns[dn++]=$2}
    /Driver Version/ {dvs[dv++]=$2}
    /Queue Depth/ {qds[qd++]=$2}

    END {
        for (idx in hba_ids) 
             printf "%-11s | %-9s| %s\n", 
                hba_states[idx], 
                hba_ids[idx], 
                hba_names[idx] 
        printf "\n"
        for (idx in hba_ids) 
             printf "%s | %s| %s | %s | %s \n", 
                hba_ids[idx], 
                pcis[idx], 
                qds[idx], 
                dns[idx], 
                dvs[idx] 
    }'
        

