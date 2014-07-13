title;
		* ESM.  As I Addedd a lag of load I did so in Production, this may get folded into production;

%let ForecastSeries = lz1;
%let DateVariable = datetime;
*let PredictedTemperature = ts5;
%let RoleVariable = role;
%let ESM_model=seasonal; /*other options include linear and winters (also, seasonal does not complain about negatives like winters does)*/
%let ESM_transform=boxcox(2);

libname g 'C:\Users\anhutz\Desktop\msa\TimeSeries\PROJECTS\GEFCom2012\data';
proc expand data=g.gef out=gexpand; convert &ForecastSeries.; run; quit; 


data gexpand;
  set gexpand(where=(&ForecastSeries.^=.));  *no covariates for esm, but still GEF;
run;

proc sql; 
select count(*) 
 into : inputnumobs 
 from gexpand; 
quit;
%let train1_limit_Nminus48=%eval(&inputnumobs-48);
%put train1_limit_Nminus48=&train1_limit_Nminus48;


data train1 hold1; 
set gexpand; 
if _n_ <= &train1_limit_Nminus48 then output train1; 
else output hold1; 
run;


%macro OneSteppingLoop(h=HOURofDay, d=DAYofWeek, m=MONTHofYear);

%do i= 1 %to 48 %by 1; 

	PROC ESM data=train1 print=none plot=none lead=1 out=train1;
		id &DateVariable. interval=hour;
		forecast &ForecastSeries. / model=&ESM_model. transform=&ESM_transform.;
	RUN; 
    QUIT;

%end;

data train3;
set train1;
if _n_ > &train1_limit_Nminus48 then output;
run;


proc sql;
               create table working_holdact as
			    select actual.*, forec.&ForecastSeries. as predicted_Load label="Predicted Forecasts of &ForecastSeries."
				  from hold1 as actual, train3 as forec
				   where actual.&DateVariable.=forec.&DateVariable.  
		;
  select sqrt(avg(se)) as rmse, sqrt(avg(sa)) as rmsa, avg(abs(&ForecastSeries.-predicted_Load)/&ForecastSeries.) as mape, (calculated rmse)/(calculated rmsa) as prmse_a
   from 
	  (  select *, (&ForecastSeries.-predicted_Load)**2 as se, (&ForecastSeries.)**2 as sa
		  from working_holdact
	   )
  ;
quit;


title "Forecast Horizon, Actuals v. Forecasts, no temperature for ESM.";
proc sgplot data=working_holdact;
series x=&DateVariable. y=&ForecastSeries.       / lineattrs=(thickness=1);
series x=&DateVariable. y=predicted_Load         / lineattrs=(thickness=1);
*series x=&DateVariable. y=&PredictedTemperature. / lineattrs=(thickness=1 color=yellow) y2axis;
run; quit;


%mend OneSteppingLoop;
options mprint mlogic nosymbolgen;
%OneSteppingLoop;




/*

GLM1: Tu's (optional 4 holidays) :
	*Tu Nghiems original .2 model; 
	PROC GLM DATA=getastep_prediction
			PLOTS=NONE NOPRINT /* heard NOPRINT can change answers, may move to ods close all ods select ~predict1_onestepiter */
		;
		CLASS &d. &h. &m.;
		MODEL &ForecastSeries. =
		/* Main Effects:  */ 
					trend 
					&m.
					L_1
					/*PredictedTemperature NOT included as main effect*/
		        /* 2-way Interactions: */
					&d.*&h.
				/* Temperature x hour */
					&PredictedTemperature.*&h.
					T2_0*&h. 
					T3_0*&h. 
					T1_1*&h. 
					T2_1*&h. 
					T3_1*&h. 
				/* Temperature x month */
					&PredictedTemperature.*&m.
					T2_0*&m. 
					T3_0*&m. 
					T1_1*&m. 
					T2_1*&m.	 
					T3_1*&m. 
				/* Load interactions: */
				    L_1*&h. 
					L_1*&m. 
				/* Holidays: */
					july4   	
					new_year
					thanks
					christmas
		;
		RUN;

		OUTPUT OUT= predict1_onestepiter (WHERE=(NOT __FLAG))
			PREDICTED=predicted_Load ;
		RUN;
	QUIT;


*GLM2 nonhierarchical three-ways for parsimony UNTESTED
	PROC GLM DATA=getastep_prediction
			PLOTS=NONE NOPRINT 
		;
		CLASS &d. &h. &m.;
		MODEL &ForecastSeries. =
		/* Main Effects:  */ 
					trend 


                    &PredictedTemperature. 

				/* 2 way */
				    &h.*&m.
		/* 3-way Interactions: */
					&PredictedTemperature.*&h.*&d.
					T2_0*&h.*&d.
					T3_0*&h.*&d. 
					T1_1*&h.*&d. 
					T2_1*&h.*&d. 
					T3_1*&h.*&d. 
				/* Load interaction: */
				    L_1*&h.*&m. 
		;
		RUN;