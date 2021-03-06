#!/usr/bin/perl
use strict;
use warnings;

print "\nPlease install VirtualBox first...\n\n" if system("VBoxManage -v > /dev/null 2>&1") != 0;
my $vm_name;my $guest_os;
my $filename = 'FagrantFile';
if ( -e $filename ) {
    open my $fh, '<', $filename or die "Can't open $filename: $!\n";
    chomp( $vm_name = <$fh> );
    close $fh or die "Can't close $filename: $!\n";
    vm_state( $vm_name, 'exists' ) or die "VM from $filename doesn't exist. :x\n";
    $guest_os = `VBoxManage showvminfo $vm_name | grep 'Guest OS'`;
}
my $subroutines = {'init' => \&init, 'up' => \&up, 'provision' => \&provision, 'ssh' => \&ssh, 'bake' => \&bake, 'halt' => \&halt, 'destroy' => \&destroy};
$ARGV[0] && $ARGV[0] =~ /(init|up|provision|ssh|bake|halt|destroy)/ ? $subroutines->{$ARGV[0]}->() : help();

sub vm_state {
    my ($vm_name, $state) = @_;
    return grep {/^"(.+)"\s{1}[^"]+$/;$vm_name eq $1} `VBoxManage list vms` if $state eq 'exists';
    return grep {/^"(.+)"\s{1}[^"]+$/;$vm_name eq $1} `VBoxManage list runningvms` if $state eq 'running';
}

sub init {
    $vm_name and die "Wow wow, there's already a fagrant VM for this directory?! Are you crazy?\n";
    vm_state($ARGV[1], 'exists') or die "Sorry, couldn't find a VM with the name '$vm_name'.\n";
    $vm_name = $ARGV[1] . "_" . time();

    print "Cloning VM with name '$vm_name'.\n";
    print `VBoxManage clonevm $ARGV[1] --name "$vm_name"`;
    my $vm_directory = shift [ map {/Default machine folder:\s+(.+)$/;$1} grep {/^Default machine folder:/} `VBoxManage list systemproperties` ];
    my $vm_location = $vm_directory . '/' . $vm_name . '/' . $vm_name . '.vbox';
    print `VBoxManage registervm "$vm_location"`;

    open my $fh, '>', $filename or die "Can't open $filename: $!\n";
    print {$fh} $vm_name;
    close $fh or die "Can't close $filename: $!\n";
}

sub up {
    if( !$vm_name && $ARGV[1] && vm_state($ARGV[1], 'exists') ) {
        $vm_name = $ARGV[1];
        $guest_os = `VBoxManage showvminfo $vm_name | grep 'Guest OS'`;
        open my $fh, '>', $filename or die "Can't open $filename: $!\n";
        print {$fh} $vm_name;
        close $fh or die "Can't close $filename: $!\n";
    } 
    $vm_name or die "Either use 'fagrant up <vm_name>' or 'fagrant init <vm_name> && fagrant up'.\n";
    my $port = 2000 + int(rand(1000));

    `VBoxManage modifyvm "$vm_name" --natpf1 delete "guestssh" > /dev/null 2>&1` if $guest_os !~ /windows/i;
    `VBoxManage modifyvm "$vm_name" --natpf1 "guestssh,tcp,,$port,,22" > /dev/null 2>&1` if $guest_os !~ /windows/i;
    `VBoxManage sharedfolder remove "$vm_name" --name guestfolder > /dev/null 2>&1`;
    `VBoxManage sharedfolder add "$vm_name" --name "guestfolder" --hostpath $ENV{PWD} --automount > /dev/null 2>&1`;
    my $window_type = ($guest_os =~ /windows/i) ? 'gui' : 'headless';
    print "Booting VM...\n";
    system("VBoxManage startvm --type $window_type \"$vm_name\" > /dev/null 2>&1 &");
}

sub provision {
    ssh("sudo mount -t vboxsf -o uid=\$(id -u),gid=\$(id -g) guestfolder /fagrant");
    ssh("puppet apply /fagrant/manifests/default.pp");
}

sub ssh {
    ($vm_name && $guest_os !~ /windows/i) or die "Either you haven't called 'fagrant (init|up)' or you trying to ssh to a Windows VM (currently unsupported).\n";
    my $user = $ARGV[1] // "fagrant";
    my $command = $_[0] // "";
    my $keyfile = $user eq 'vagrant' ? $ENV{HOME} . '/.vagrant.d/insecure_private_key' : $ENV{HOME} . '/.ssh/fagrant';
    my $ssh_port = shift [ map {/host port = (\d+),/;$1} grep {/NIC \d+ Rule.+guest port = 22/} `VBoxManage showvminfo "$vm_name"` ];
    system("ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i $keyfile $user\@localhost -p $ssh_port $command") if $vm_name && vm_state($vm_name, 'running');
}

sub bake {
    $vm_name or return;
    my $snapshot_name = $ARGV[1] // "snapshot_" . time();
    my $comment = $ARGV[2] // "";
    `VBoxManage snapshot "$vm_name" take "$snapshot_name" --description "$comment"`;
    `VBoxManage controlvm "$vm_name" resume > /dev/null 2>&1`;
}

sub halt {
    my $method = $ARGV[1] && $ARGV[1] eq '--force' ? 'poweroff' : 'acpipowerbutton';
    system("VBoxManage controlvm \"$vm_name\" $method") if $vm_name && vm_state($vm_name, 'running');
}

sub destroy {
    $vm_name or return;
    halt() if vm_state($vm_name, 'running');
    if(not defined $ARGV[1]) {
        print "Not so fast José! U sure? "; # I know myself, I need this.
        `VBoxManage unregistervm "$vm_name" --delete` if <STDIN> =~ /^ye?s?/i;
    }
    sleep(3) and `VBoxManage snapshot "$vm_name" restorecurrent > /dev/null 2>&1` if $ARGV[1] && $ARGV[1] eq '--revert';
    unlink($filename);
}

sub help {
    print "\nFagrant - does what vagrant does, only in 100 loc.\n\n\t$0 init <VM name> - Initialize new VM in current working directory, cloned from <VM name>\n\t$0 up - Boot the VM\n\t$0 provision - Provision the VM\n\t$0 ssh <user> - SSH into the box\n\t$0 bake <name> <description> - Bakes the current state of the VM\n\t$0 halt - Halt the VM\n\t$0 destroy - Destroy the VM\n\t$0 destroy --revert - Revert the VM to latest snapshot and remove FagrantFile\n\t$0 help - Print this\n\n";
}
