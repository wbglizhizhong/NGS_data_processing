#!/usr/bin/perl
# 2015-05-29 
#   Workflow: 
#    1. Set windows according to [Win_Chr, Win_Start, Win_End, Win_Len, Win_Step]; 
#    2. Divide the whole input table to small tables, each table stands for a window; 
#    3. (Multi-core) Count PI/theta/tajima_D/... values for each whole window; 
#    4. Output values by window; 
#    5. Remove temporary files. 
# 2015-06-01 In this workflow, I ignored windows with no SNP sites in the table. So if needed, we 
#   should setup a basic window list. 
use strict; 
use warnings; 

use Bio::PopGen::Statistics; 
use Bio::PopGen::Individual; 
use Bio::PopGen::Genotype; 

# An example of how to use this. 
use Parallel::ForkManager; 
#my $MAX_PROCESSES = 10; 
#my $pm = new Parallel::ForkManager($MAX_PROCESSES); 
#for my (my $i=0; $i<100; $i++) {
#	my $pid = $pm->start and next; 
#	$pm->finish; 
#}
#$pm->wait_all_children; 

use Getopt::Long; 

use fileSunhh; 
use LogInforSunhh; 
use mathSunhh; 
my $ms_obj = mathSunhh->new(); 

############################################################
# Basic settings 
############################################################
my %opts; 
my (%wind, @chrIDs); 


############################################################
# Main 
############################################################
&tsmsg("[Rec] Start.\n"); 

&set_opts(); 
&load_snp_tbl(); 
&setup_windows(); 
&dvd_snp_tbl(); 
&cnt_val(); 
&out_data(); 
&del_tmp(); 

&tsmsg("[Rec] Done.\n"); 

############################################################
# Sub-routines 
############################################################

sub usage {
	print <<HH; 
############################################################
# perl $0 -snp_tbl input_SNP.tbl -value_types 'pi,theta,tajima_D'
# 
# -help 
# 
# -snp_tbl          [filename] 
# -value_types      ['pi,theta,tajima_D']
# -ncpu             [1]
#
# -out              [*STDOUT] Output file storing the values per window. 
#                   
# -wind_start       [1]
# -wind_end         [99999999]
# -wind_end_useMax  [Boolean] If given, the max positions of each chr are recorded, 
#                     and the windows larger than this value are deleted. 
# -wind_length      [10000]
# -wind_step        [1000]
# -chr_colN         [0] column of chromosome. 
# -pos_colN         [1] column of position on chromosome. 
# -skipHN           [0] Skip header lines number.
# -geno_col         [''] By default I will use the columns in the first reading line except chr_colN and pos_colN; 
############################################################
HH
	exit 1; 
}

# Set options from the input; 
sub set_opts {
	&tsmsg("[Msg] Setup options.\n"); 
	GetOptions(\%opts, 
		"help!", 
		"snp_tbl:s", 
		"out:s", 
		"value_types:s", 
		"ncpu:i", 
		"wind_start:i", "wind_end:i", "wind_end_useMax!", "wind_length:i", "wind_step:i", 
		"chr_colN:i", "pos_colN:i", 
		"skipHN:i", 
		"geno_col:s", 
	); 
	$opts{'help'} and &usage(); 
	-t and !(defined $opts{'snp_tbl'}) and &usage(); 
	&prepare_input_fh(); 
	&prepare_cnt_stat(); 
	$opts{'_inner'}{'outFh'} = \*STDOUT; 
	defined $opts{'out'} and $opts{'_inner'}{'outFh'} = &openFH($opts{'out'}, '>'); 
	
	$opts{'ncpu'} //= 1; 
	$opts{'wind_start'} //= 1; 
	$opts{'wind_end'}   //= 99999999; 
	$opts{'wind_length'} //= 10000; 
	$opts{'wind_step'} //= 1000; 
	$opts{'wind_end_useMax'} //= undef(); 
	$opts{'chr_colN'}  //= 0; 
	$opts{'pos_colN'}  //= 1; 
	$opts{'geno_col'} //= ''; 
	$opts{'geno_cols'} = [ &mathSunhh::_parseCol( $opts{'geno_col'} ) ]; 
	# Usable keys: 
	#  'inFh'  => file_handle of input. 
	#  'cnt_stat' => [ stat_value_to_be_counted ]
	#  'wind_start|end|length|step' => global parameters to setup windows. 
	#  'wind_end_useMax' => False. If True, will trim windows by CHR's maximum position; 
	#  'chr|pos_colN'    => columns for indexing. 
	#  'geno_cols' => [@cols_to_use]
}# sub set_opts() 

# Setup $opts{'inFh'} and skip $opts{'skipHN'} lines; 
sub prepare_input_fh {
	&tsmsg("[Msg] Prepare input file.\n"); 
	$opts{'inFh'} = \*STDIN; 
	defined $opts{'snp_tbl'} and $opts{'inFh'} = &openFH($opts{'snp_tbl'}, '<'); 
	$opts{'skipHN'} //= 0; 
	for ( 1 .. $opts{'skipHN'} ) {
		readline($opts{'inFh'}); 
	}
	return 0; 
	#  'skipHN'   => number of lines to skip from head of file. 
}# sub prepare_input_fh () 

# Setup $opts{'cnt_stat'}; 
sub prepare_cnt_stat {
	&tsmsg("[Msg] Record types of statistics.\n"); 
	$opts{'value_types'} //= 'pi,theta,tajima_D'; 
	$opts{'cnt_stat'} = [ map { s!\s!!g; $_; } split(/,/, $opts{'value_types'})]; 
	# Maybe I can add sub-function to a hash. 
	return 0; 
}# prepare_cnt_stat() 

# Setup $opts{'_inner'}{'tbl_lines'} : recording [@data_lines]; 
sub load_snp_tbl {
	&tsmsg("[Msg] Loading data.\n"); 
	@{ $opts{'_inner'}{'tbl_lines'} } = readline( $opts{'inFh'} ) ; 
	chomp(@{$opts{'_inner'}{'tbl_lines'}}); 
	my $nn = scalar( @{$opts{'_inner'}{'tbl_lines'}} ); 
	&tsmsg("[Msg] $nn lines data loaded.\n"); 
	return 0; 
}# load_snp_tbl () 

# Setup ($opts{'geno_cols'}, %wind, @chrIDs); 
sub setup_windows {
	&tsmsg("[Msg] Setting up windows.\n"); 
	if ( scalar(@{$opts{'geno_cols'}}) == 0 ) { 
		my $ln = $opts{'_inner'}{'tbl_lines'}[0]; 
		my @ta = split(/\t/, $ln); 
		for (my $i=0; $i<@ta; $i++) {
			$i == $opts{'chr_colN'} and next; 
			$i == $opts{'pos_colN'} and next; 
			push(@{$opts{'geno_cols'}}, $i); 
		}
	}
	scalar(@{$opts{'geno_cols'}}) == 0 and &stopErr("[Err] No good geno_cols available. Try use -geno_col\n"); 
	
	# Setup %wind; {chr}
	for (@{$opts{'_inner'}{'tbl_lines'}}) {
		my @ta = split(/\t/, $_); 
		my $cur_chr = $ta[ $opts{'chr_colN'} ]; 
		my $cur_pos = $ta[ $opts{'pos_colN'} ]; 
		defined $opts{'_inner'}{'max_pos'}{$cur_chr} or do { push(@chrIDs, $cur_chr); $opts{'_inner'}{'max_pos'}{$cur_chr} = $cur_pos; }; 
		$opts{'_inner'}{'max_pos'}{$cur_chr} < $cur_pos and $opts{'_inner'}{'max_pos'}{$cur_chr} = $cur_pos; 
	}
	for my $cur_chr ( @chrIDs ) {
		my $max_len = ( $opts{'wind_end_useMax'} ) ? $opts{'_inner'}{'max_pos'}{$cur_chr} : $opts{'wind_end'} ; 
		$wind{$cur_chr} = $ms_obj->setup_windows(
		  'ttl_start'   =>  $opts{'wind_start'}, 
		  'ttl_end'     =>  $max_len, 
		  'wind_size'   =>  $opts{'wind_length'}, 
		  'wind_step'   =>  $opts{'wind_step'}, 
		  'minRatio'    =>  0, 
		); 
	}
	return 0; 
}# setup_windows() 

# Setup smaller snp_tbl files ( @{$opts{'_inner'}{'tmp_wind_file'}} ). 
#  $opts{'_inner'}{'tmp_dir'}
#  $opts{'_inner'}{'windFN2windTI'} : {wind_filename}=>[chrID, chr_wind_idx]
#  $opts{'_inner'}{'chrIdx2fIdx'}   : {chrID}{wind_idx} => file_idx 
sub dvd_snp_tbl {
	&tsmsg("[Msg] Dividing windows.\n"); 
	$opts{'_inner'}{'tmp_dir'} = &fileSunhh::new_tmp_dir(); 
	defined $opts{'_inner'}{'tmp_dir'} or &stopErr("[Err] failed to find a temporary directory.\n"); 
	my $tmpDir = $opts{'_inner'}{'tmp_dir'}; 
	mkdir($tmpDir); 
	my %used; 
	for ( @{$opts{'_inner'}{'tbl_lines'}} ) {
		my @ta = split(/\t/, $_); 
		my $cur_chr = $ta[ $opts{'chr_colN'} ]; 
		my $cur_pos = $ta[ $opts{'pos_colN'} ]; 
		my (@wind_i) = @{ $ms_obj->map_windows( 'posi'=>$cur_pos, 'wind_hash'=>$wind{$cur_chr} ) }; 
		for my $ti ( @wind_i ) {
			my $file_idx; 
			if ( defined $opts{'_inner'}{'chrIdx2fIdx'}{$cur_chr}{$ti} ) {
				$file_idx = $opts{'_inner'}{'chrIdx2fIdx'}{$cur_chr}{$ti}; 
			} else {
				$file_idx = $ms_obj->newNumber(); 
				$opts{'_inner'}{'chrIdx2fIdx'}{$cur_chr}{$ti} = $file_idx; 
			}
			my $wind_fname = "$tmpDir/wind_${file_idx}"; 
			$opts{'_inner'}{'windFN2windTI'}{$wind_fname} = [$cur_chr, $ti]; 
			&fileSunhh::write2file($wind_fname, "$_\n", '>>'); 
			defined $used{$wind_fname} or do { push(@{$opts{'_inner'}{'tmp_wind_file'}}, $wind_fname); $used{$wind_fname} = 1; }; 
		}
	}
}# dvd_snp_tbl () 

sub cnt_val {
	&tsmsg("[Msg] Counting statistics.\n"); 
	my $MAX_PROCESSES = $opts{'ncpu'}; 
	my $pm = new Parallel::ForkManager($MAX_PROCESSES); 
	for my $inFname ( @{$opts{'_inner'}{'tmp_wind_file'}} ) {
		my $pid = $pm->start and next; 
		&cnt_val_1tbl($inFname, "${inFname}.val") || &exeCmd_1cmd("touch ${inFname}.val.OK"); 
		$pm->finish; 
	}
	$pm->wait_all_children; 
	return 0; 
}# sub cnt_val () 

sub out_data {
	&tsmsg("[Msg] Output result.\n"); 
	print {$opts{'_inner'}{'outFh'}} join("\t", qw/ChrID WindS WindE WindL/, @{$opts{'cnt_stat'}})."\n"; 
	for my $inFname ( @{$opts{'_inner'}{'tmp_wind_file'}} ) {
		my ($chrID, $chrWsi) = @{ $opts{'_inner'}{'windFN2windTI'}{$inFname} }; 
		my ($wS, $wE, $wL) = @{ $wind{$chrID}{'loci'}{$chrWsi} }; 
		unless ( -e "${inFname}.val.OK" ) {
			&tsmsg("[Err] Failed to count values for $inFname storing ${chrID} - [ $wS , $wE ]\n"); 
			next; 
		}
		open F,'<',"$inFname.val" or &stopErr("[Err] Failed to open file $inFname.val\n"); 
		my $outL = <F>; chomp($outL); 
		close F; 
		print {$opts{'_inner'}{'outFh'}} join("\t", $chrID, $wS, $wE, $wL) . "\t$outL\n"; 
	}
	close ($opts{'_inner'}{'outFh'}); 
	return 0; 
}# sub out_data () 

sub del_tmp {
	&tsmsg("[Msg] Delete temporary Dir: $opts{'_inner'}{'tmp_dir'}\n"); 
	&fileSunhh::_rmtree( $opts{'_inner'}{'tmp_dir'} ); 
	return 0; 
}

sub cnt_val_1tbl {
	my ($inTblFile, $outValFile) = @_; 
	$outValFile //= "${inTblFile}.val"; 
	# Setup individuals obj
	my @inds; 
	my @ncols = @{ $opts{'geno_cols'} }; 
	for (my $i=0; $i<@ncols; $i++) {
		$inds[$i] = Bio::PopGen::Individual->new(
		  -unique_id   => $i, 
		  -genotypes   => []
		); 
	}
	# Add genotypes
	my $fh = &openFH($inTblFile, "<"); 
	while (<$fh>) {
		chomp; 
		my @ta = split(/\t/, $_); 
		my $cur_chr = $ta[ $opts{'chr_colN'} ]; 
		my $cur_pos = $ta[ $opts{'pos_colN'} ]; 
		my $marker_name = "${cur_chr}_${cur_pos}"; 
		for (my $i=0; $i < @ncols; $i++ ) {
			my @geno; 
			$ta[$i] = uc($ta[$i]); 
			if ( $ta[$i] =~ m/^[ATGC]$/ ) {
				@geno = ($ta[$i], $ta[$i]); 
			} elsif ( $ta[$i] =~ m/^([ATGC])([ATGC])$/ ) {
				@geno = ($1, $2); 
			} else {
				@geno = ('N', 'N'); 
			}
			$inds[$i]->add_Genotype(
			  Bio::PopGen::Genotype->new(
			    -alleles     => [@geno], 
			    -marker_name => $marker_name 
			  )
			); 
		}
	}# End while ()
	close($fh); 
#	my $pop = Bio::PopGen::Population->new(
#	  -name        => 'pop_tmp', 
#	  -description => 'pop_tmp', 
#	  -individuals => [@inds]
#	); 
	my %val; 
	my $stats = Bio::PopGen::Statistics->new(); 
	my @out_arr; 
	# These are values not normalized. 
	for my $type (@{$opts{'cnt_stat'}}) {
		defined $val{$type} and do { push(@out_arr, $val{$type}); next; }; 
		if ( $type =~ m!^pi$!i ) {
			$val{$type} = $stats->pi(\@inds); 
		} elsif ( $type =~ m!^theta$!i ) {
			$val{$type} = $stats->theta(\@inds); 
		} elsif ( $type =~ m!tajima_?D!i ) {
			$val{$type} = $stats->tajima_D(\@inds); 
		} else {
			&stopErr("[Err] Unknown type to count [$type]\n"); 
		}
		push(@out_arr, $val{$type}); 
	}
	&fileSunhh::write2file("$outValFile", join("\t", @out_arr)."\n", '>'); 
	return 0; 
}# sub cnt_val_1tbl () 

############################################################
############################################################

