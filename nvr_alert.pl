#!/usr/bin/perl

use File::Basename;
use File::Find;
use File::stat;
use Date::Manip;
use Time::localtime;
use LWP::UserAgent;
use Astro::Sunrise;
use Data::Dumper;
use DBI;

# set to be lat and long of your location to correctly compute the
# sunrise/sunset
$lat="37.3318";
$long="122.0312";
# Set to be the base location of where images should be looked for.
# This is assuming that within this directory you have subdirectories for each
# camera (i.e. Front_Door, Back_Door, etc.) and that your camera is configured
# to save the pictures to the proper subdirectory via FTP.
$loc = "/storage/samba/Pictures/NVR";
# Assuming all images uploaded are .jpg files
$extensions =  qw'\.jpg';
# number of minutes to suppress alerts around sunrise/sunset when IR sensor changes; this is
# in both directions; so X minutes before and X minutes after sunrise/sunset
$false_mins = "20";
# days of images to keep. script needs to be run as an id that has permissions
# to remove the files. set to 0 if you want to keep them forever.
$days_to_keep="30";
# URL of the PHP file. 
$url="http://myraspberrypiwebserver.homenet.org/cam/index.php";
# don't send events within x mins of each other.
$max_notify_interval="10"; 
# Database info.  This should match config.php
# Database schema should be included. 
$database="cam";
$hostname="localhost";
$username="cam";
$password="cam";
###

$data_source= "DBI:mysql:database=$database;host=$hostname;port=3306";
$dbh = DBI->connect($data_source, $username, $password) ||
  print "Cannot connect to $data_source: $dbh->errstr\n";

$sta = $dbh->prepare("select * from images where 1");
$sta->execute or print $DBI::errstr;
$files=$sta->fetchall_hashref("image");

find(\&findfiles,$loc);

$sta = $dbh->prepare("select count(id) from images where notified=0");
$sta->execute or print $DBI::errstr;
$count=$sta->fetchrow;

if ($count>0) {
	# if we have images, load up the users
	if ($max_notify_interval > 0) {
		$q="select * from users where DATE_SUB(NOW(),INTERVAL $max_notify_interval MINUTE) > lastNotify";
	} else {
		$q="select * from users where 1";
	}
	$sta = $dbh->prepare($q);
	$sta->execute or print $DBI::errstr;
	$users=$sta->fetchall_hashref("user");
	$size = keys %$users;
}

if ($size>0) {
	# if we have users to notify...
	$date = &ParseDate("now");
	$hour = &UnixDate($date,"%H"); 
	$sunrise = sun_rise($long,$lat);
	$sunset = sun_set($long,$lat);
	$sunrise_d= ParseDate($sunrise);
	$sunset_d= ParseDate($sunset);
	$delta = DateCalc($sunrise_d,$date);
	$minutes_sr= Delta_Format($delta,1,"%mt");
	$delta = DateCalc($sunset_d,$date);
	$minutes_ss= Delta_Format($delta,1,"%mt");

	$skip=0;
	#print "$hour\n";
	&checkFalseAlarm($minutes_sr);
	&checkFalseAlarm($minutes_ss);

	#$count = $count/2;
        $stb=$dbh->prepare("select distinct(location) from images where notified=0");
        $stb->execute or print $DBI::errstr;
	while($location = $stb->fetchrow_array) {
		$locations{$location}++; 
		$stc=$dbh->prepare("select ignore_ranges from cameras where location=?");
		$stc->execute($location) or print $DBI::errstr;
		while(my $range = $stc->fetchrow_array) {
			my (@ranges)=split(/\,/,$range);
			foreach my $t_slice (@ranges) {
				my ($s,$e)=split(/\-/,$t_slice);
				my $ret = &checkRange($s,$e);
				if ($ret eq 1) {
					$locations{$location}--;
					$ignore="found ignore range $t_slice for $location";
				}
			}
		}
	}

	$loc_count=0;
	foreach $location (keys %locations) {
		if ($locations{$location} eq 1) {
			$loc_string .= join(", ",$location) . ", ";
			$loc_count++;
		}
	}

	chop($loc_string);
	chop($loc_string);
		
	if (!$skip && $loc_count > 0) {
		$sta = $dbh->prepare("delete from suppress where expiration < NOW()");
		$sta->execute or print $DBI::errstr;
		$sta = $dbh->prepare("select authkey from suppress where expiration >= NOW()");
		$sta->execute or print $DBI::errstr;
		while ($row=$sta->fetchrow_arrayref) {
			$suppress{$row->[0]}++;
		}
		foreach $user (keys %$users) {
			if (!$suppress{$users->{$user}{'authkey'}} && $users->{$user}{'enabled'}) {
				if (($hour > 21) || ($hour < 6)) { 
					$link = "$url?time=half&auth=$users->{$user}{'authkey'}";
				} else {
					$link = "$url?&auth=$users->{$user}{'authkey'}";
				}
				
				$sta = $dbh->prepare("update users set lastNotify=NOW() where user=?");
				$sta->execute($user) or print $DBI::errstr;
				print "Notifying $user for $count $link\n";
				&pushover($users->{$user}{'pushoverApp'},$users->{$user}{'pushoverKey'},"$loc_string","$count video event(s) for $loc_string the past few minutes, please review alerts: $link","$link");
			#} else {
				#print "Skipping for $user\n";
			}
		}
	} else {
		$string = "I suppressed an alert $minutes_sr $minutes_ss ($ignore)$ link\n";
		# uncomment  and add your pushover App ID and pushover API key to debug suppressed alerts
		#&pushover("PushOverAPPID","PushOverAPIKey","","$string","$link");
	}
	$sta = $dbh->prepare("update images set notified=1 where notified=0");
	$sta->execute or print $DBI::errstr;
	&doExpire();
}

sub doExpire {
        if ($days_to_keep > 0)  {
                $sta = $dbh->prepare("select id,image from images where DATE_SUB(NOW(),INTERVAL $days_to_keep DAY) > date");
                $sta->execute or print $DBI::errstr;
                while ($row=$sta->fetchrow_arrayref) {
                        if (-w "$loc/$row->[1]") {
                                system("rm -f \"$loc/$row->[1]\"");
                        }
                        $stb = $dbh->prepare("delete from images where id=?");
                        $stb->execute($row->[0]) or print $DBI::errstr;
                }
        }
}

sub checkRange {
	my ($s,$e) = @_;
	(@start)=split(/:/,$s);
	(@end)=split(/:/,$e);
	
	if ($start[0] < 10) {
		$start[0]='0'. $start[0];
	}
	if ($end[0] < 10) {
		$end[0]='0' . $end[0];
	}
	if ($end[0] < $start[0]) {
		$end_date = ParseDate("tomorrow");
		$end_date= &UnixDate($end_date,"%m/%d/%y"); 
	} else {
		$end_date = &UnixDate($date,"%m/%d/%y"); 
	}
	$start_date = &UnixDate($date,"%m/%d/%y"); 

	$start_date .= " $start[0]";
	$end_date .= " $end[0]";
	if ($start[1]) {
		$start_date .= ":$start[1]:00";
	} else {
		$start_date .= ":00:00";
	}
	if ($end[1]) {
		$end_date .= ":$end[1]:00";
	} else {
		$end_date .= ":00:00";
	}
	$start_date=ParseDate($start_date);
	$end_date=ParseDate($end_date);
	$sret=Date_Cmp($start_date,$date);
	$eret=Date_Cmp($date,$end_date);
	if ($sret <=0 && $eret <=0) {
		return 1;
	} 
	return 0
}

sub checkFalseAlarm {
    my $delta = shift;
    $delta =~ s/\-//; 
    if ($delta <= $false_mins) {
	$skip=1;
    }
}

sub pushover {
	my $app=shift;
	my $user=shift;
	my $loc=shift;
	my $msg=shift;
	my $link=shift;

	use LWP::UserAgent;

	LWP::UserAgent->new()->post(
  	"https://api.pushover.net/1/messages.json", [
  	"token" => "$app",
  	"user" => "$user",
        "title" => "Video events for $loc",
  	"message" => "$msg",
        "url" => "$link",
]);
}

sub findfiles {
  my $full = $File::Find::name;
  my $file = $_;
  my $dir = dirname($full);
	
  return unless $full =~ m/$extensions/io;
  my $subdir = $dir;
  $subdir =~ s/$loc\///g;
  $basefile=$subdir . "/$file";
  $subdir =~ s/\_/ /g;
  return if ($files->{$basefile});
  my $st = stat($full);
  $sta = $dbh->prepare("insert into images VALUES(\"\",?,FROM_UNIXTIME(?),?,0)");
  $sta->execute($basefile,$st->mtime,$subdir) or print $DBI::errstr;
}
