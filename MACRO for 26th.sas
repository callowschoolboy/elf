libname load "C:\Users\Tu\Documents\Fall Classes\Time Series\Load Forecasting\Data";


*This step creates  some variables from the original data set;
*Andrew: You 'd probably have to run this step since in my GLM model I named T_1 (which Kris has) as TEMP_1;

data load.phase1;
	set load.phase1;
	temp2=temp**2;
	temp3=temp**3;
	temp_1=lag(temp);
	temp_diff=dif(temp);
	load_1=lag(load);
	
	temp_1_2=temp_1**2;
	temp_1_3=temp_1**3;
	
run;

*count the number of observation in the data set;
Data _null_;
	set load.phase1 end=last;
	if last then call symput ('N', input(_n_  ,20.));
run;

%put &N; 

*Substract 48 from the total number of observations;
*N2 is the length of the first training set;
*length is a macro variable to build the Benchmark data set after the big macro, just ignore it for now;
%let N2=%eval(&N - 72);
%let length=&N2;
%put &N2;
/*%put &N3;*/

*Initial Step: Set up the training set before macro;
data load.phase1_training;
	set load.phase1 (obs= &N2);
run;



**RUN THE ABOVE DATA STEP BEFORE EVERY MACRO RUN OR THE ESTIMATES WILL MESS UP;



****Description for the macro;
****Data set: phase1_holdoff has the next observation that we want
				Phase1_training has the training data
				Prediction has the training data and the one obs from the phase1_hold off data, and for obs's load for the last obs is 
				missing (to feed to GLM);


%macro glm (g=48);



*do loop for 1 to 48;
%do i=72 %to &g %by -1; 

*Substract  the total number of observations;
%let N2=%eval(&N - &i);
%put &N2;




*data step to hold off the next observation;
data load.phase1_holdoff;
	
	set load.phase1;
	if _n_=&N2+1 then output;
	
run;



**IMPORTANT: we have to recalculate the lagged load (LOAD_1) with the predicted value;
**For the first iteration of the loop, it is simply the ACTUAL value of the last obs, but for other iterations,
			it is the FORECASTED value of the previous observation;
DATA load.prediction;
	SET load.phase1_training(IN=__ORIG) load.phase1_holdoff;
	__FLAG=__ORIG;
	__DEP=Load;
	load_1=lag(load);
	if not __FLAG then Load=.;
RUN;


*model and output the predictions to the load.predicted data set (rough version);
PROC GLM DATA=load.prediction
		PLOTS(ONLY)=ALL
	;
	CLASS weekday hour month;
	MODEL Load=	 trend weekday*hour month
				temp*hour temp2*hour temp3*hour 
				month*temp month*temp2 month*temp3 
				temp_1*hour temp_1_2*hour temp_1_3*hour 
				temp_1*month temp_1_2*month	 temp_1_3*month 
				load_1 load_1*hour load_1*month 
				
				july4 new_year thanks christmas
		/
		SS1
		SS3
		SOLUTION
		SINGULAR=1E-07
	;
	RUN;

	OUTPUT OUT= load.predicted (WHERE=(NOT __FLAG))
		PREDICTED=predicted_Load ;
	RUN;
QUIT;









*need to update the training set with predicted values;

*N3 needs to calculate to get the next value for the training set;
%let N3=%eval(&N2+1);
%put &N3;

*Get the next value for the training set, this step is kinda redundant since we already have the HOLDOFF set, but it was late at night,
		And it is the same idea;
data load.phase1_training2;
	obs=&n3;
	
	set load.phase1;
	if _n_=obs then output;
	
	%put load=;
	
run;

%put mergingggggg;

*append predicted_load as load into the training set;
data load.phase1_training (drop=predicted_load);
	set load.phase1_training(in=good) load.phase1_training2 (in=__flag);
	if good then output;
	if __flag then do;
	set load.predicted (keep=predicted_load);
	load=predicted_load;
	output;
	end;
run;


quit;
%end;
%mend;

%glm (g=48);



%let n4= %eval(&length +1);
%put &length;

*Print out the forecasted values,all 48 of them;
data load.validation;
	set load.phase1 (firstobs= &n4);
	if  _N_ <= 24 then output;
run;


*create the benchmark data set;
data load.benchmark (keep= Date Hour Load Predicted_load ABE APE );
	set load.phase1_training(rename=(load=predicted_load) firstobs=&n4);
	set load.validation;
	label predicted_load ="predicted_load";
	ABE=abs(predicted_load-load);
	APE= ABE/load;
	if _n_ <= 24 then output;

run;


*find MAPE;
proc SQL;
select avg(ABE) as MABE,
		avg(APE) as MAPE
from load.benchmark;
quit;


